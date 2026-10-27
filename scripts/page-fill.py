#!/usr/bin/env python3
"""Type into a Chromium page on this computer without keeping a copy of the text.

The caller names a display and the fields. This process writes each value
through Chrome's debugging connection, then drops it. Nothing here is written
to a log.
"""
import base64
import json
import os
import re
import socket
from urllib.parse import urlsplit
from urllib.request import urlopen

FIELD_ID = re.compile(r"^[a-z][a-z0-9_]{0,31}$")

MAX_VALUE = 2000


class FillError(Exception):
    def __init__(self, code: str, field: str | None = None) -> None:
        super().__init__(code)
        self.code = code
        self.field = field


def display_number(display: str) -> int:
    number = display.lstrip(":").split(".", 1)[0]
    if not number.isdigit():
        raise FillError("bad_display")
    return int(number)


def cdp_port(display: str) -> int:
    """Same port coforge-chromium uses: 9222 plus the X display number."""
    return 9222 + display_number(display)


def validate_fields(fields) -> list:
    if not isinstance(fields, list) or not fields or len(fields) > 8:
        raise FillError("bad_request")
    seen = set()
    clean = []
    for field in fields:
        if not isinstance(field, dict):
            raise FillError("bad_request")
        ident = field.get("id")
        selector = field.get("selector")
        value = field.get("value")
        kind = field.get("input")
        if (
            not isinstance(ident, str)
            or FIELD_ID.fullmatch(ident) is None
            or ident in seen
            or kind not in ("text", "password")
            or not isinstance(selector, str)
            or not selector.strip()
            or len(selector) > 300
            or not isinstance(value, str)
            or len(value) > MAX_VALUE
        ):
            raise FillError("bad_request")
        if kind == "password" and value == "":
            raise FillError("bad_request")
        seen.add(ident)
        clean.append(
            {"id": ident, "selector": selector.strip(), "input": kind, "value": value}
        )
    return clean


def _attributes(node: dict) -> dict:
    raw = node.get("attributes") or []
    return dict(zip(raw[0::2], raw[1::2]))


# Runs in the open page. Walks iframes and shadow roots so a CSS selector the
# Agent named still hits a React/SPA field. Values are not returned.
_FILL_PAGE = r"""(function(spec) {
  function passwordInput(el) {
    return !!(el && el.nodeName === "INPUT" && String(el.type).toLowerCase() === "password");
  }
  function search(root, selector) {
    if (!root) return null;
    try {
      if (root.querySelector) {
        const hit = root.querySelector(selector);
        if (hit) return hit;
      }
    } catch (e) {}
    const nodes = root.querySelectorAll ? root.querySelectorAll("*") : [];
    for (const node of nodes) {
      if (node.shadowRoot) {
        const inner = search(node.shadowRoot, selector);
        if (inner) return inner;
      }
      if (node.tagName === "IFRAME") {
        try {
          const inner = search(node.contentDocument, selector);
          if (inner) return inner;
        } catch (e) {}
      }
    }
    return null;
  }
  const el = search(document, spec.selector);
  if (!el) return "not_found";
  if (spec.password && !passwordInput(el)) return "not_a_password_field";
  el.focus();
  const proto = el.nodeName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const desc = Object.getOwnPropertyDescriptor(proto, "value");
  if (desc && desc.set) desc.set.call(el, spec.value);
  else el.value = spec.value;
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  return "ok";
})"""


def _evaluate_status(result) -> str | None:
    if not isinstance(result, dict) or result.get("exceptionDetails"):
        return None
    value = (result.get("result") or {}).get("value")
    if value in ("ok", "not_found", "not_a_password_field"):
        return value
    return None


def fill_with(session, fields: list) -> list:
    """Focus each selector and insert its text. Password targets must be password inputs."""
    session.call("Runtime.enable")
    filled = []
    pending = []
    for field in fields:
        spec = {
            "selector": field["selector"],
            "value": field["value"],
            "password": field["input"] == "password",
        }
        result = session.call(
            "Runtime.evaluate",
            {
                "expression": f"({_FILL_PAGE})({json.dumps(spec)})",
                "returnByValue": True,
            },
        )
        status = _evaluate_status(result)
        if status == "ok":
            filled.append(field["id"])
            continue
        if status == "not_a_password_field":
            raise FillError("not_a_password_field", field["id"])
        pending.append(field)
    if pending:
        session.call("DOM.enable")
        document = session.call("DOM.getDocument", {"depth": -1, "pierce": True})
        root = document.get("root", {}).get("nodeId") or 0
        if not root:
            raise FillError("field_not_found", pending[0]["id"])
        targets = []
        for field in pending:
            found = session.call(
                "DOM.querySelector", {"nodeId": root, "selector": field["selector"]}
            )
            node = found.get("nodeId") or 0
            if not node:
                raise FillError("field_not_found", field["id"])
            if field["input"] == "password":
                described = session.call("DOM.describeNode", {"nodeId": node})
                info = described.get("node") or {}
                attrs = _attributes(info)
                if info.get("nodeName", "").lower() != "input" or attrs.get("type") != "password":
                    raise FillError("not_a_password_field", field["id"])
            targets.append((field, node))
        for field, node in targets:
            session.call("DOM.focus", {"nodeId": node})
            session.call(
                "Input.dispatchKeyEvent",
                {
                    "type": "keyDown",
                    "modifiers": 2,
                    "key": "a",
                    "code": "KeyA",
                    "windowsVirtualKeyCode": 65,
                },
            )
            session.call(
                "Input.dispatchKeyEvent",
                {
                    "type": "keyUp",
                    "modifiers": 2,
                    "key": "a",
                    "code": "KeyA",
                    "windowsVirtualKeyCode": 65,
                },
            )
            session.call("Input.insertText", {"text": field["value"]})
            filled.append(field["id"])
    for field in fields:
        field["value"] = ""
    return filled


def list_pages(port: int) -> list:
    try:
        with urlopen(f"http://127.0.0.1:{port}/json/list", timeout=2) as response:
            listed = json.load(response)
    except (OSError, ValueError):
        return []
    if not isinstance(listed, list):
        return []
    return [
        page
        for page in listed
        if isinstance(page, dict)
        and page.get("type") == "page"
        and isinstance(page.get("webSocketDebuggerUrl"), str)
    ]


def fill_display(display: str, fields, list_pages_fn=list_pages, connect=None) -> dict:
    clean = validate_fields(fields)
    try:
        port = cdp_port(display)
    except FillError:
        raise
    pages = list_pages_fn(port)
    if not pages:
        raise FillError("browser_not_open")
    opener = connect or WebsocketCdp
    last = FillError("field_not_found")
    for page in pages:
        session = opener(page["webSocketDebuggerUrl"])
        try:
            return {"filled": fill_with(session, clean)}
        except FillError as exc:
            last = exc
            if exc.code not in ("field_not_found", "not_a_password_field"):
                raise
        finally:
            close = getattr(session, "close", None)
            if close:
                close()
    raise last


class WebsocketCdp:
    def __init__(self, url: str) -> None:
        parsed = urlsplit(url)
        if parsed.scheme != "ws" or not parsed.hostname or not parsed.port:
            raise FillError("browser_not_open")
        self._sock = socket.create_connection((parsed.hostname, parsed.port), 5)
        self._sock.settimeout(8)
        path = parsed.path or "/"
        if parsed.query:
            path = f"{path}?{parsed.query}"
        key = base64.b64encode(os.urandom(16)).decode()
        host = f"{parsed.hostname}:{parsed.port}"
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self._sock.sendall(request.encode())
        header = b""
        while b"\r\n\r\n" not in header:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise FillError("browser_not_open")
            header += chunk
            if len(header) > 65536:
                raise FillError("browser_not_open")
        status = header.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            raise FillError("browser_not_open")
        self._buf = bytearray(header.split(b"\r\n\r\n", 1)[1])
        self._next = 0

    def close(self) -> None:
        try:
            self._sock.close()
        except OSError:
            pass

    def call(self, method: str, params=None):
        self._next += 1
        ident = self._next
        body = {"id": ident, "method": method}
        if params is not None:
            body["params"] = params
        self._send(json.dumps(body).encode())
        while True:
            message = json.loads(self._recv())
            if message.get("id") != ident:
                continue
            if "error" in message:
                raise FillError("browser_not_open")
            return message.get("result") or {}

    def _send(self, payload: bytes) -> None:
        mask = os.urandom(4)
        header = bytearray([0x81])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += length.to_bytes(2, "big")
        else:
            header.append(0x80 | 127)
            header += length.to_bytes(8, "big")
        header += mask
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self._sock.sendall(bytes(header) + masked)

    def _recv(self) -> bytes:
        while True:
            frame = self._read_frame()
            opcode = frame[0]
            if opcode == 0x8:
                raise FillError("browser_not_open")
            if opcode == 0x9:
                self._pong(frame[1])
                continue
            if opcode == 0x1:
                return frame[1]

    def _pong(self, payload: bytes) -> None:
        header = bytearray([0x8A, 0x80 | len(payload)])
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self._sock.sendall(bytes(header) + mask + masked)

    def _read_exact(self, size: int) -> bytes:
        while len(self._buf) < size:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise FillError("browser_not_open")
            self._buf += chunk
        out = bytes(self._buf[:size])
        del self._buf[:size]
        return out

    def _read_frame(self) -> tuple:
        header = self._read_exact(2)
        opcode = header[0] & 0x0F
        masked = header[1] & 0x80
        length = header[1] & 0x7F
        if length == 126:
            length = int.from_bytes(self._read_exact(2), "big")
        elif length == 127:
            length = int.from_bytes(self._read_exact(8), "big")
        mask = self._read_exact(4) if masked else b""
        payload = self._read_exact(length) if length else b""
        if mask:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        return opcode, payload
