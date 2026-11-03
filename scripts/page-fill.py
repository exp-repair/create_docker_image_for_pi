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
    """Public proxy port for this display (9222 + number). Requires path token."""
    return 9222 + display_number(display)


def chromium_profile_dir(display: str, home: str | None = None) -> str:
    root = home if home is not None else os.environ.get("HOME", "/root")
    return os.path.join(root, ".config", "coforge-chromium", str(display_number(display)))


def cdp_token(display: str, home: str | None = None) -> str | None:
    path = os.path.join(chromium_profile_dir(display, home), "cdp.token")
    try:
        with open(path, encoding="utf-8") as handle:
            value = handle.read().strip()
    except OSError:
        return None
    if len(value) == 32 and all(ch in "0123456789abcdef" for ch in value):
        return value
    return None


def cdp_base_url(display: str, home: str | None = None) -> str | None:
    """Tokenized public CDP base, or None when this display has no token yet."""
    token = cdp_token(display, home)
    if not token:
        return None
    return f"http://127.0.0.1:{cdp_port(display)}/coforge-cdp/{token}/"


def cdp_port_from_profile(display: str, home: str | None = None) -> int | None:
    """Backend port Chromium last used for this display's profile, if any."""
    profile = chromium_profile_dir(display, home)
    for name in ("cdp.backend", "DevToolsActivePort"):
        path = os.path.join(profile, name)
        try:
            with open(path, encoding="utf-8") as handle:
                first = handle.readline().strip()
        except OSError:
            continue
        if first.isdigit():
            port = int(first)
            if 1 <= port <= 65535:
                return port
    return None


def cdp_ports(display: str, home: str | None = None) -> list[int]:
    """Legacy helper: public proxy port only (token required separately)."""
    return [cdp_port(display)]


def validate_fields(fields) -> list:
    """Selector is optional when a label is present, or the field is a password input."""
    if not isinstance(fields, list) or not fields or len(fields) > 8:
        raise FillError("bad_request")
    seen = set()
    clean = []
    for field in fields:
        if not isinstance(field, dict):
            raise FillError("bad_request")
        ident = field.get("id")
        selector = field.get("selector")
        label = field.get("label")
        value = field.get("value")
        kind = field.get("input")
        if selector is None:
            selector = ""
        if label is None:
            label = ""
        if (
            not isinstance(ident, str)
            or FIELD_ID.fullmatch(ident) is None
            or ident in seen
            or kind not in ("text", "password")
            or not isinstance(selector, str)
            or len(selector) > 300
            or not isinstance(label, str)
            or len(label) > 80
            or not isinstance(value, str)
            or len(value) > MAX_VALUE
        ):
            raise FillError("bad_request")
        selector = selector.strip()
        label = label.strip()
        if not selector and not label and kind != "password":
            raise FillError("bad_request")
        if kind == "password" and value == "":
            raise FillError("bad_request")
        seen.add(ident)
        clean.append(
            {
                "id": ident,
                "selector": selector,
                "label": label,
                "input": kind,
                "value": value,
            }
        )
    return clean


def _attributes(node: dict) -> dict:
    raw = node.get("attributes") or []
    return dict(zip(raw[0::2], raw[1::2]))


# Shared DOM helpers for fill and inspect. Walks iframes and shadow roots.
_PAGE_HELPERS = r"""
  function passwordInput(el) {
    return !!(el && el.nodeName === "INPUT" && String(el.type).toLowerCase() === "password");
  }
  function visible(el) {
    if (!el || !el.getBoundingClientRect) return false;
    const rect = el.getBoundingClientRect();
    if (rect.width < 1 || rect.height < 1) return false;
    const style = window.getComputedStyle ? window.getComputedStyle(el) : null;
    if (style && (style.visibility === "hidden" || style.display === "none")) return false;
    return true;
  }
  function walk(root, visit) {
    if (!root) return;
    visit(root);
    const nodes = root.querySelectorAll ? root.querySelectorAll("*") : [];
    for (const node of nodes) {
      if (node.shadowRoot) walk(node.shadowRoot, visit);
      if (node.tagName === "IFRAME") {
        try { walk(node.contentDocument, visit); } catch (e) {}
      }
    }
  }
  function search(root, selector) {
    if (!root || !selector) return null;
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
  function labelText(el) {
    const bits = [];
    if (el.getAttribute) {
      for (const name of ["aria-label", "placeholder", "name", "autocomplete", "title"]) {
        const value = el.getAttribute(name);
        if (value) bits.push(value);
      }
    }
    if (el.id && el.ownerDocument) {
      try {
        const byFor = el.ownerDocument.querySelector('label[for="' + CSS.escape(el.id) + '"]');
        if (byFor && byFor.textContent) bits.push(byFor.textContent);
      } catch (e) {}
    }
    try {
      const wrapped = el.closest && el.closest("label");
      if (wrapped && wrapped.textContent) bits.push(wrapped.textContent);
    } catch (e) {}
    return bits.join(" ").replace(/\s+/g, " ").trim();
  }
  function matchLabel(el, want) {
    if (!want) return false;
    const hay = labelText(el).toLowerCase();
    const needle = String(want).toLowerCase().trim();
    return !!(needle && hay && hay.indexOf(needle) !== -1);
  }
  function resolve(spec) {
    if (spec.selector) {
      const bySelector = search(document, spec.selector);
      if (bySelector) return bySelector;
    }
    let labeled = null;
    let fallback = null;
    walk(document, function(root) {
      if (labeled || !root.querySelectorAll) return;
      const inputs = root.querySelectorAll("input, textarea");
      for (const el of inputs) {
        if (!visible(el)) continue;
        const type = el.nodeName === "TEXTAREA" ? "text" : String(el.type || "text").toLowerCase();
        if (spec.password) {
          if (type !== "password") continue;
          if (spec.label && matchLabel(el, spec.label)) { labeled = el; return; }
          if (!fallback) fallback = el;
          continue;
        }
        if (type === "password" || type === "hidden" || type === "submit" || type === "button" || type === "checkbox" || type === "radio" || type === "file") continue;
        if (spec.label && matchLabel(el, spec.label)) { labeled = el; return; }
        if (!fallback) fallback = el;
      }
    });
    return labeled || fallback;
  }
"""

# Runs in the open page. Values are not returned.
_FILL_PAGE = (
    r"""(function(spec) {"""
    + _PAGE_HELPERS
    + r"""
  const el = resolve(spec);
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
)

_INSPECT_PAGE = (
    r"""(function() {"""
    + _PAGE_HELPERS
    + r"""
  function cssEscape(value) {
    if (window.CSS && CSS.escape) return CSS.escape(value);
    return String(value).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
  }
  function suggestSelector(el) {
    if (el.id) return "#" + cssEscape(el.id);
    const name = el.getAttribute && el.getAttribute("name");
    if (name) return el.nodeName.toLowerCase() + '[name="' + name.replace(/"/g, '\\"') + '"]';
    const type = el.nodeName === "TEXTAREA" ? "text" : String(el.type || "text").toLowerCase();
    if (type === "password") return 'input[type=password]';
    if (type && type !== "text") return 'input[type="' + type + '"]';
    return el.nodeName.toLowerCase();
  }
  function suggestId(el, input, used) {
    const raw = (el.id || el.getAttribute("name") || (input === "password" ? "password" : "field") || "field")
      .toLowerCase()
      .replace(/[^a-z0-9_]+/g, "_")
      .replace(/^_+|_+$/g, "");
    let base = raw.match(/^[a-z][a-z0-9_]{0,31}$/) ? raw : (input === "password" ? "password" : "field");
    let ident = base;
    let n = 2;
    while (used[ident]) {
      const suffix = String(n++);
      ident = (base.slice(0, Math.max(1, 32 - suffix.length)) + suffix);
    }
    used[ident] = true;
    return ident;
  }
  const used = {};
  const fields = [];
  walk(document, function(root) {
    if (!root.querySelectorAll) return;
    const inputs = root.querySelectorAll("input, textarea");
    for (const el of inputs) {
      if (!visible(el)) continue;
      const type = el.nodeName === "TEXTAREA" ? "text" : String(el.type || "text").toLowerCase();
      if (type === "hidden" || type === "submit" || type === "button" || type === "checkbox" || type === "radio" || type === "file" || type === "image" || type === "reset") continue;
      const input = type === "password" ? "password" : "text";
      const label = labelText(el).slice(0, 80);
      fields.push({
        id: suggestId(el, input, used),
        label: label || (input === "password" ? "Password" : "Text"),
        input: input,
        selector: suggestSelector(el).slice(0, 300),
      });
      if (fields.length >= 8) return;
    }
  });
  return fields;
})"""
)


def _evaluate_status(result) -> str | None:
    if not isinstance(result, dict) or result.get("exceptionDetails"):
        return None
    value = (result.get("result") or {}).get("value")
    if value in ("ok", "not_found", "not_a_password_field"):
        return value
    return None


def fill_with(session, fields: list) -> list:
    """Focus each field and insert its text. Password targets must be password inputs.

    A field may name a CSS selector, or omit it and resolve by label / password type.
    """
    session.call("Runtime.enable")
    filled = []
    pending = []
    for field in fields:
        spec = {
            "selector": field.get("selector") or "",
            "label": field.get("label") or "",
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
        # DOM fallback only when a concrete selector was provided.
        if field.get("selector"):
            pending.append(field)
        else:
            raise FillError("field_not_found", field["id"])
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


def inspect_with(session) -> list:
    """List visible text/password fields on the page with suggested selectors."""
    session.call("Runtime.enable")
    result = session.call(
        "Runtime.evaluate",
        {"expression": f"({_INSPECT_PAGE})()", "returnByValue": True},
    )
    if not isinstance(result, dict) or result.get("exceptionDetails"):
        return []
    value = (result.get("result") or {}).get("value")
    if not isinstance(value, list):
        return []
    clean = []
    seen = set()
    for field in value:
        if not isinstance(field, dict):
            continue
        ident = field.get("id")
        label = field.get("label")
        kind = field.get("input")
        selector = field.get("selector")
        if (
            not isinstance(ident, str)
            or FIELD_ID.fullmatch(ident) is None
            or ident in seen
            or kind not in ("text", "password")
            or not isinstance(label, str)
            or not label.strip()
            or len(label) > 80
            or not isinstance(selector, str)
            or not selector.strip()
            or len(selector) > 300
        ):
            continue
        seen.add(ident)
        clean.append(
            {
                "id": ident,
                "label": label.strip(),
                "input": kind,
                "selector": selector.strip(),
            }
        )
        if len(clean) >= 8:
            break
    return clean


def list_pages(base_url: str) -> list:
    """List pages from a tokenized CDP base URL (…/coforge-cdp/<token>/)."""
    url = base_url if base_url.endswith("/") else base_url + "/"
    try:
        with urlopen(url + "json/list", timeout=2) as response:
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


def _open_pages(
    display: str,
    list_pages_fn=list_pages,
    home: str | None = None,
) -> tuple[str, list]:
    try:
        display_number(display)
    except FillError:
        raise
    base = cdp_base_url(display, home)
    if not base:
        raise FillError("browser_not_open")
    pages = list_pages_fn(base)
    if not pages:
        raise FillError("browser_not_open")
    return base, pages


def fill_display(
    display: str,
    fields,
    list_pages_fn=list_pages,
    connect=None,
    home: str | None = None,
) -> dict:
    clean = validate_fields(fields)
    _base, pages = _open_pages(display, list_pages_fn=list_pages_fn, home=home)
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


def inspect_display(
    display: str,
    list_pages_fn=list_pages,
    connect=None,
    home: str | None = None,
) -> dict:
    """Return visible form fields on this display's Chromium pages."""
    _base, pages = _open_pages(display, list_pages_fn=list_pages_fn, home=home)
    opener = connect or WebsocketCdp
    for page in pages:
        session = opener(page["webSocketDebuggerUrl"])
        try:
            fields = inspect_with(session)
            if fields:
                return {"fields": fields}
        finally:
            close = getattr(session, "close", None)
            if close:
                close()
    return {"fields": []}


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


def main(argv: list[str] | None = None) -> int:
    """CLI: inspect the current DISPLAY's open page, printing field JSON."""
    import argparse
    import sys

    parser = argparse.ArgumentParser(description="Inspect or fill Chromium fields on this display")
    parser.add_argument(
        "--inspect",
        action="store_true",
        help="list visible text/password fields as JSON (no secrets)",
    )
    parser.add_argument(
        "--display",
        default=os.environ.get("DISPLAY", ""),
        help="X display, default $DISPLAY",
    )
    args = parser.parse_args(argv)
    if not args.inspect:
        parser.error("only --inspect is supported on the CLI; filling goes through the desktop /fill API")
    if not args.display:
        print("DISPLAY unset", file=sys.stderr)
        return 2
    try:
        result = inspect_display(args.display)
    except FillError as exc:
        print(json.dumps({"error": exc.code}), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
