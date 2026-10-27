#!/usr/bin/env python3
"""Browser desktop on VNC_WS_PORT.

The page talks WebSocket. This process checks a token, logs into the local VNC
server with the password kept in the container, and then gives the browser an
open session. The VNC password is not sent to the page.
"""
import base64
import hashlib
import hmac
import importlib.util
import json
import os
import posixpath
import secrets
import socket
import threading
from urllib.parse import parse_qs, urlsplit

WS_PORT = int(os.environ.get("VNC_WS_PORT", "6080"))
VNC_HOST = "127.0.0.1"
VNC_PORT = int(os.environ.get("VNC_PORT", "5901"))
NOVNC_ROOT = "/usr/share/novnc"
PAGE_PATH = "/usr/local/share/coforge/vnc-desktop.html"
TOKEN_PATH = "/root/.vnc/ws-token.txt"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_FRAME = 8 * 1024 * 1024

_REV = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))
_IP = (
    58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
    62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
    57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
    61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
)
_FP = (
    40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
    38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
    36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
    34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
)
_E = (
    32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13,
    14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27,
    28, 29, 28, 29, 30, 31, 32, 1,
)
_P = (
    16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
    2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25,
)
_PC1 = (
    57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35,
    27, 19, 11, 3, 60, 52, 44, 36, 63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38,
    30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4,
)
_PC2 = (
    14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7,
    27, 20, 13, 2, 41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56,
    34, 53, 46, 42, 50, 36, 29, 32,
)
_SHIFTS = (1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1)
_SBOX = (
    (
        14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
        0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
        4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
        15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
    ),
    (
        15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
        3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
        0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
        13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
    ),
    (
        10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
        13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
        13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
        1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
    ),
    (
        7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
        13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
        10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
        3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
    ),
    (
        2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
        14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
        4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
        11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
    ),
    (
        12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
        10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
        9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
        4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
    ),
    (
        4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
        13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
        1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
        6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
    ),
    (
        13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
        1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
        7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
        2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
    ),
)


def log(message: str) -> None:
    print(f"[vnc-web] {message}", flush=True)


def permute(value: int, table: tuple, width: int) -> int:
    out = 0
    for pos in table:
        out = (out << 1) | ((value >> (width - pos)) & 1)
    return out


def des_encrypt_block(block: bytes, key: bytes) -> bytes:
    left = permute(int.from_bytes(key, "big"), _PC1, 64)
    c = (left >> 28) & 0x0FFFFFFF
    d = left & 0x0FFFFFFF
    subkeys = []
    for shift in _SHIFTS:
        c = ((c << shift) | (c >> (28 - shift))) & 0x0FFFFFFF
        d = ((d << shift) | (d >> (28 - shift))) & 0x0FFFFFFF
        subkeys.append(permute((c << 28) | d, _PC2, 56))
    left = permute(int.from_bytes(block, "big"), _IP, 64)
    l = (left >> 32) & 0xFFFFFFFF
    r = left & 0xFFFFFFFF
    for subkey in subkeys:
        expanded = permute(r, _E, 32) ^ subkey
        substituted = 0
        for box in range(8):
            six = (expanded >> (42 - 6 * box)) & 0x3F
            row = ((six & 0x20) >> 4) | (six & 1)
            col = (six >> 1) & 0xF
            substituted = (substituted << 4) | _SBOX[box][row * 16 + col]
        l, r = r, l ^ permute(substituted, _P, 32)
    return permute((r << 32) | l, _FP, 64).to_bytes(8, "big")


def obfuscate_vnc_password(password: str) -> bytes:
    """TigerVNC passwd file: password encrypted with the fixed VNC key."""
    raw = password.encode("latin-1", "replace")[:8].ljust(8, b"\x00")
    key = bytes(_REV[b] for b in (23, 82, 107, 6, 35, 78, 88, 7))
    return des_encrypt_block(raw, key)


def vnc_response(challenge: bytes, password: str) -> bytes:
    raw = password.encode("latin-1", "replace")[:8].ljust(8, b"\x00")
    key = bytes(_REV[b] for b in raw)
    return des_encrypt_block(challenge[:8], key) + des_encrypt_block(challenge[8:16], key)


def read_exact(sock: socket.socket, size: int) -> bytes:
    buf = bytearray()
    while len(buf) < size:
        chunk = sock.recv(size - len(buf))
        if not chunk:
            raise ConnectionError("connection closed")
        buf += chunk
    return bytes(buf)


def load_password() -> str:
    password = os.environ.get("VNC_PASSWORD", "").strip()
    if password:
        return password
    for _ in range(100):
        try:
            with open("/root/.vnc/password.txt", encoding="utf-8") as handle:
                password = handle.read().strip()
        except OSError:
            password = ""
        if password:
            return password
        threading.Event().wait(0.1)
    raise ConnectionError("VNC password is not ready")


def login_to_vnc(sock: socket.socket, password: str) -> None:
    banner = read_exact(sock, 12)
    if not banner.startswith(b"RFB "):
        raise ConnectionError("desktop did not speak VNC")
    sock.sendall(b"RFB 003.008\n")
    count = read_exact(sock, 1)[0]
    if count == 0:
        length = int.from_bytes(read_exact(sock, 4), "big")
        reason = read_exact(sock, min(length, 512)).decode("utf-8", "replace")
        raise ConnectionError(reason or "desktop rejected the session")
    types = read_exact(sock, count)
    if 2 not in types:
        raise ConnectionError("desktop has no password login")
    sock.sendall(bytes([2]))
    challenge = read_exact(sock, 16)
    sock.sendall(vnc_response(challenge, password))
    result = int.from_bytes(read_exact(sock, 4), "big")
    if result != 0:
        raise ConnectionError("VNC login failed")


class Stream:
    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.buf = bytearray()
        self.lock = threading.Lock()

    def read(self, size: int) -> bytes:
        while len(self.buf) < size:
            opcode, payload = read_frame(self.sock)
            if opcode == 0x8:
                raise ConnectionError("browser closed")
            if opcode == 0x9:
                send_frame(self.sock, 0xA, payload, self.lock)
                continue
            if opcode == 0xA:
                continue
            if opcode in (0x1, 0x2):
                self.buf += payload
        out = bytes(self.buf[:size])
        del self.buf[:size]
        return out

    def write(self, payload: bytes) -> None:
        send_frame(self.sock, 0x2, payload, self.lock)


def read_frame(sock: socket.socket) -> tuple[int, bytes]:
    opcode = None
    parts = []
    while True:
        header = read_exact(sock, 2)
        fin = header[0] & 0x80
        op = header[0] & 0x0F
        masked = header[1] & 0x80
        length = header[1] & 0x7F
        if length == 126:
            length = int.from_bytes(read_exact(sock, 2), "big")
        elif length == 127:
            length = int.from_bytes(read_exact(sock, 8), "big")
        if length > MAX_FRAME:
            raise ConnectionError("websocket frame too large")
        mask = read_exact(sock, 4) if masked else b""
        payload = read_exact(sock, length) if length else b""
        if mask:
            payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
        if op in (0x8, 0x9, 0xA):
            return op, payload
        if op == 0:
            if opcode is None:
                raise ConnectionError("broken websocket frame")
        else:
            opcode = op
        parts.append(payload)
        if fin:
            return opcode or 0x2, b"".join(parts)


def send_frame(sock: socket.socket, opcode: int, payload: bytes, lock: threading.Lock) -> None:
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header += length.to_bytes(2, "big")
    else:
        header.append(127)
        header += length.to_bytes(8, "big")
    with lock:
        sock.sendall(bytes(header) + payload)


def prepare_token() -> str:
    os.makedirs("/root/.vnc", mode=0o700, exist_ok=True)
    token = os.environ.get("VNC_WS_TOKEN", "").strip()
    if token:
        log(f"web desktop on :{WS_PORT}; using VNC_WS_TOKEN")
        return token
    token = secrets.token_urlsafe(24)
    with open(TOKEN_PATH, "w", encoding="utf-8") as handle:
        handle.write(token + "\n")
    os.chmod(TOKEN_PATH, 0o600)
    log(f"web desktop on :{WS_PORT}; token written to {TOKEN_PATH}")
    return token


def token_ok(presented: str, expected: str) -> bool:
    got = presented.encode()
    want = expected.encode()
    if len(got) != len(want):
        return False
    return hmac.compare_digest(got, want)


def header_map(head: str) -> dict[str, str]:
    lines = head.split("\r\n")
    found = {}
    for line in lines[1:]:
        if ":" not in line:
            continue
        name, value = line.split(":", 1)
        found[name.strip().lower()] = value.strip()
    return found


def request_token(headers: dict[str, str], query: str) -> str:
    if headers.get("x-vnc-token"):
        return headers["x-vnc-token"]
    values = parse_qs(query, keep_blank_values=False).get("token") or []
    return values[0] if values else ""


def send_http(conn: socket.socket, status: str, body: bytes, content_type: str) -> None:
    head = (
        f"HTTP/1.1 {status}\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n"
        "\r\n"
    )
    conn.sendall(head.encode() + body)


def content_type(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    return {
        ".html": "text/html; charset=utf-8",
        ".js": "text/javascript; charset=utf-8",
        ".css": "text/css; charset=utf-8",
        ".svg": "image/svg+xml",
        ".png": "image/png",
        ".ico": "image/x-icon",
        ".json": "application/json",
        ".woff": "font/woff",
        ".woff2": "font/woff2",
    }.get(ext, "application/octet-stream")


def novnc_file(url_path: str) -> str:
    rel = posixpath.normpath(url_path).lstrip("/")
    full = os.path.normpath(os.path.join(NOVNC_ROOT, rel))
    root = os.path.normpath(NOVNC_ROOT)
    if full != root and not full.startswith(root + os.sep):
        raise FileNotFoundError(url_path)
    if not os.path.isfile(full):
        raise FileNotFoundError(url_path)
    return full


def accept_browser(stream: Stream) -> bytes:
    stream.write(b"RFB 003.008\n")
    version = stream.read(12)
    if not version.startswith(b"RFB "):
        raise ConnectionError("browser did not speak VNC")
    stream.write(bytes([1, 1]))
    if stream.read(1) != b"\x01":
        raise ConnectionError("browser rejected the desktop session")
    stream.write(b"\x00\x00\x00\x00")
    return stream.read(1)


def pump_desktop(vnc: socket.socket, stream: Stream) -> None:
    def outward() -> None:
        try:
            while True:
                data = vnc.recv(65536)
                if not data:
                    break
                stream.write(data)
        except OSError:
            pass
        finally:
            try:
                stream.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    threading.Thread(target=outward, daemon=True).start()
    try:
        while True:
            opcode, payload = read_frame(stream.sock)
            if opcode == 0x8:
                break
            if opcode == 0x9:
                send_frame(stream.sock, 0xA, payload, stream.lock)
                continue
            if opcode in (0x1, 0x2) and payload:
                vnc.sendall(payload)
    finally:
        vnc.close()


def bridge(conn: socket.socket, vnc_port: int = VNC_PORT) -> None:
    vnc = socket.create_connection((VNC_HOST, vnc_port), 10)
    # The connect timeout stays on the socket. A still desktop sends no bytes,
    # so the next recv would fail after 10s and drop the browser session.
    vnc.settimeout(None)
    vnc.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    try:
        login_to_vnc(vnc, load_password())
        stream = Stream(conn)
        client_init = accept_browser(stream)
        vnc.sendall(client_init)
        if stream.buf:
            vnc.sendall(stream.buf)
            stream.buf.clear()
        pump_desktop(vnc, stream)
    finally:
        vnc.close()


def load_page_fill():
    sibling = os.path.join(os.path.dirname(os.path.abspath(__file__)), "page-fill.py")
    spec = importlib.util.spec_from_file_location("page_fill", sibling)
    if spec is None or spec.loader is None:
        raise RuntimeError("page-fill.py is missing")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_chunked(conn: socket.socket, rest: bytes):
    buf = bytearray(rest)
    body = bytearray()

    def need(size: int) -> bool:
        while len(buf) < size:
            chunk = conn.recv(4096)
            if not chunk:
                return False
            buf.extend(chunk)
        return True

    while True:
        while b"\r\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                return None
            buf.extend(chunk)
        line, _, leftover = bytes(buf).partition(b"\r\n")
        buf[:] = leftover
        try:
            size = int(line.split(b";", 1)[0].strip(), 16)
        except ValueError:
            return None
        if size == 0:
            while b"\r\n" not in buf:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf.extend(chunk)
            return bytes(body)
        if size < 0 or len(body) + size > 65536:
            return None
        if not need(size + 2):
            return None
        body.extend(buf[:size])
        del buf[:size]
        if buf[:2] != b"\r\n":
            return None
        del buf[:2]


def read_body(conn: socket.socket, headers: dict, rest: bytes):
    if "chunked" in headers.get("transfer-encoding", "").lower():
        return read_chunked(conn, rest)
    raw = headers.get("content-length", "")
    if not raw.isdigit():
        return None
    length = int(raw)
    if length > 65536:
        return None
    body = bytearray(rest)
    while len(body) < length:
        chunk = conn.recv(length - len(body))
        if not chunk:
            return None
        body += chunk
    return bytes(body[:length])


def handle_fill(conn: socket.socket, headers: dict, query: str, rest: bytes, token: str, display: str) -> None:
    """Write the posted fields into Chromium. The body is not logged."""
    if not token_ok(request_token(headers, query), token):
        send_http(conn, "401 Unauthorized", b"", "text/plain")
        return
    body = read_body(conn, headers, rest)
    if body is None:
        send_http(conn, "400 Bad Request", b"", "text/plain")
        return
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError, TypeError):
        send_http(conn, "400 Bad Request", b"", "text/plain")
        return
    fields = payload.get("fields") if isinstance(payload, dict) else None
    module = load_page_fill()
    try:
        result = module.fill_display(display, fields)
    except module.FillError as exc:
        status = "409 Conflict" if exc.code == "browser_not_open" else "422 Unprocessable Entity"
        if exc.code in ("bad_request", "bad_display"):
            status = "400 Bad Request"
        reply = {"error": exc.code}
        if exc.field:
            reply["field"] = exc.field
        send_http(conn, status, json.dumps(reply).encode(), "application/json")
        return
    send_http(conn, "200 OK", json.dumps(result).encode(), "application/json")


def handle_http(conn: socket.socket, expected_token: str) -> None:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return
        data += chunk
        if len(data) > 65536:
            send_http(conn, "431 Request Header Fields Too Large", b"", "text/plain")
            return
    head, rest = bytes(data).split(b"\r\n\r\n", 1)
    text = head.decode("iso-8859-1", "replace")
    request = text.split("\r\n", 1)[0]
    try:
        method, target, _proto = request.split(" ")
    except ValueError:
        send_http(conn, "400 Bad Request", b"", "text/plain")
        return
    parsed = urlsplit(target)
    headers = header_map(text)
    screen = SCREEN_TARGET(parsed.path) if SCREEN_TARGET is not None else None
    if method == "POST" and (parsed.path == "/fill" or (screen is not None and screen[1] == "fill")):
        agent_id = screen[0] if screen is not None and screen[1] == "fill" else ""
        display = os.environ.get("VNC_DISPLAY", ":1")
        if agent_id and SCREENS is not None:
            found = SCREENS.lookup(agent_id)
            if found and found.get("display"):
                display = found["display"]
        handle_fill(conn, headers, parsed.query, rest, expected_token, display)
        return
    if screen is not None and method == "GET":
        agent_id, kind = screen
        if kind == "page":
            with open(PAGE_PATH, "rb") as handle:
                send_http(conn, "200 OK", handle.read(), "text/html; charset=utf-8")
            return
        if kind == "socket":
            if not token_ok(request_token(headers, parsed.query), expected_token):
                send_http(conn, "401 Unauthorized", b"", "text/plain")
                return
            key = headers.get("sec-websocket-key", "")
            if not key:
                send_http(conn, "400 Bad Request", b"", "text/plain")
                return
            accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
            reply = (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n"
                "\r\n"
            )
            conn.sendall(reply.encode())
            try:
                port = SCREENS.open_viewer(agent_id)
                bridge(BufferedSocket(conn, rest), port)
            finally:
                SCREENS.close_viewer(agent_id)
            return
        try:
            path = novnc_file("/" + kind)
        except FileNotFoundError:
            send_http(conn, "404 Not Found", b"", "text/plain")
            return
        with open(path, "rb") as handle:
            send_http(conn, "200 OK", handle.read(), content_type(path))
        return
    if method == "GET" and parsed.path in ("/", "/desktop.html"):
        query = f"?{parsed.query}" if parsed.query else ""
        if parsed.path == "/":
            body = f"HTTP/1.1 302 Found\r\nLocation: /desktop.html{query}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.sendall(body.encode())
            return
        with open(PAGE_PATH, "rb") as handle:
            send_http(conn, "200 OK", handle.read(), "text/html; charset=utf-8")
        return
    if method == "GET" and parsed.path == "/websockify":
        if not token_ok(request_token(headers, parsed.query), expected_token):
            send_http(conn, "401 Unauthorized", b"", "text/plain")
            return
        key = headers.get("sec-websocket-key", "")
        if not key:
            send_http(conn, "400 Bad Request", b"", "text/plain")
            return
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        reply = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            "\r\n"
        )
        conn.sendall(reply.encode())
        bridge(BufferedSocket(conn, rest))
        return
    if method == "GET" and parsed.path.startswith("/"):
        try:
            path = novnc_file(parsed.path)
        except FileNotFoundError:
            send_http(conn, "404 Not Found", b"", "text/plain")
            return
        with open(path, "rb") as handle:
            send_http(conn, "200 OK", handle.read(), content_type(path))
        return
    send_http(conn, "404 Not Found", b"", "text/plain")


class BufferedSocket:
    def __init__(self, sock: socket.socket, pending: bytes) -> None:
        self.sock = sock
        self.buf = bytearray(pending)

    def recv(self, size: int) -> bytes:
        if self.buf:
            out = bytes(self.buf[:size])
            del self.buf[:size]
            return out
        return self.sock.recv(size)

    def sendall(self, payload: bytes) -> None:
        self.sock.sendall(payload)

    def close(self) -> None:
        self.sock.close()

    def shutdown(self, how: int) -> None:
        self.sock.shutdown(how)


def serve(conn: socket.socket, token: str) -> None:
    try:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        handle_http(conn, token)
    except ConnectionError as exc:
        log(f"session closed: {exc}")
    except Exception as exc:
        log(f"session failed: {exc}")
    finally:
        try:
            conn.close()
        except OSError:
            pass


SCREENS = None
SCREEN_TARGET = None


def load_screens():
    sibling = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vnc-agent-screen.py")
    spec = importlib.util.spec_from_file_location("vnc_agent_screen", sibling)
    if spec is None or spec.loader is None:
        raise RuntimeError("vnc-agent-screen.py is missing")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    global SCREENS, SCREEN_TARGET
    token = prepare_token()
    try:
        module = load_screens()
        SCREENS = module.AgentScreens()
        SCREEN_TARGET = module.screen_target
        module.serve_control(SCREENS)
        log(f"agent screens on 127.0.0.1:{module.CONTROL_PORT}")
    except OSError as exc:
        log(f"agent screen control failed: {exc}")
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("0.0.0.0", WS_PORT))
    listener.listen(8)
    while True:
        conn, _addr = listener.accept()
        threading.Thread(target=serve, args=(conn, token), daemon=True).start()


if __name__ == "__main__":
    main()
