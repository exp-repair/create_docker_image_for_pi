#!/usr/bin/env python3
"""Publish Chromium CDP on 0.0.0.0 and rewrite Host for Cube/Multica proxies.

Modern Chromium binds CDP to 127.0.0.1 only and rejects requests whose Host
header is not localhost / an IP. Cube routes as Host: 9223-<sid>.cube.app, so
a raw TCP forward (socat) still returns 500. This proxy:

  - listens on 0.0.0.0:PUBLIC (default 9223)
  - forwards to 127.0.0.1:INTERNAL (default 19223)
  - rewrites request Host to 127.0.0.1:INTERNAL
  - rewrites webSocketDebuggerUrl / devtoolsFrontendUrl hosts in JSON bodies
"""

from __future__ import annotations

import argparse
import os
import re
import socket
import sys
import threading
from typing import Optional, Tuple

HOST_RE = re.compile(
    rb"(?im)^(host\s*:\s*)[^\r\n]*(\r?\n)",
)
URL_HOST_RE = re.compile(
    rb"(https?|wss?)://(?:127\.0\.0\.1|localhost)(?::(\d+))?(/[^\s\"']*)?",
    re.I,
)


def recv_headers(conn: socket.socket, limit: int = 65536) -> bytes:
    data = b""
    while b"\r\n\r\n" not in data and b"\n\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
        if len(data) > limit:
            break
    return data


def split_headers(raw: bytes) -> Tuple[bytes, bytes]:
    for sep in (b"\r\n\r\n", b"\n\n"):
        idx = raw.find(sep)
        if idx >= 0:
            return raw[: idx + len(sep)], raw[idx + len(sep) :]
    return raw, b""


def rewrite_request_host(headers: bytes, internal_port: int) -> bytes:
    replacement = f"127.0.0.1:{internal_port}".encode()
    if HOST_RE.search(headers):
        # Use \g<1> — plain \1 + "127..." becomes \11 (group 11) and empties Host.
        return HOST_RE.sub(rb"\g<1>" + replacement + rb"\g<2>", headers, count=1)
    # No Host header — insert after the request line.
    nl = b"\r\n" if b"\r\n" in headers else b"\n"
    parts = headers.split(nl, 1)
    if len(parts) != 2:
        return headers
    return parts[0] + nl + b"Host: " + replacement + nl + parts[1]


def looks_like_proxy_hostname(host: Optional[str]) -> bool:
    if not host:
        return False
    h = host.split(":", 1)[0].strip().lower()
    if not h or h in {"localhost", "127.0.0.1", "0.0.0.0", "::1"}:
        return False
    # Pure IPv4 — Chromium accepts these as Host, but they are not the Cube URL.
    if re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", h):
        return False
    return True


def extract_public_host(headers: bytes) -> Optional[str]:
    # Prefer the original client host when Cube/OpenResty forwards it.
    for pattern in (
        rb"(?im)^x-forwarded-host\s*:\s*([^\r\n,]+)",
        rb"(?im)^x-original-host\s*:\s*([^\r\n]+)",
        rb"(?im)^host\s*:\s*([^\r\n]+)",
    ):
        m = re.search(pattern, headers)
        if not m:
            continue
        candidate = m.group(1).decode("latin1").strip()
        if looks_like_proxy_hostname(candidate):
            return candidate
    return None


def rewrite_json_urls(body: bytes, public_host: Optional[str], public_port: int, internal_port: int) -> bytes:
    del public_port, internal_port  # Cube embeds port in hostname; kept for call-site clarity.
    if not looks_like_proxy_hostname(public_host) or not body:
        return body

    def repl(match: re.Match[bytes]) -> bytes:
        scheme = match.group(1).lower()
        path = match.group(3) or b""
        if scheme.startswith(b"ws"):
            out_scheme = b"wss://" if scheme == b"wss" else b"ws://"
        else:
            out_scheme = b"https://" if scheme == b"https" else b"http://"
        return out_scheme + public_host.encode() + path

    return URL_HOST_RE.sub(repl, body)


def is_websocket_upgrade(headers: bytes) -> bool:
    lower = headers.lower()
    return b"upgrade: websocket" in lower


def pump(src: socket.socket, dst: socket.socket) -> None:
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass


def handle_client(
    client: socket.socket,
    internal_port: int,
    public_port: int,
) -> None:
    upstream: Optional[socket.socket] = None
    try:
        raw = recv_headers(client)
        if not raw:
            return
        headers, rest = split_headers(raw)

        # Discover external Host for JSON URL rewrite (Cube hostname).
        public_host = extract_public_host(headers)

        headers = rewrite_request_host(headers, internal_port)
        upstream = socket.create_connection(("127.0.0.1", internal_port), timeout=5)
        upstream.sendall(headers + rest)

        if is_websocket_upgrade(headers):
            # After Host rewrite, pipe transparently (includes 101 + frames).
            t = threading.Thread(target=pump, args=(upstream, client), daemon=True)
            t.start()
            pump(client, upstream)
            t.join(timeout=1)
            return

        # Plain HTTP: read response; rewrite JSON debugger URLs when possible.
        resp = recv_headers(upstream)
        if not resp:
            return
        resp_headers, resp_rest = split_headers(resp)
        lower = resp_headers.lower()
        body = resp_rest

        content_length = None
        mlen = re.search(rb"(?im)^content-length:\s*(\d+)", resp_headers)
        if mlen:
            content_length = int(mlen.group(1))
            while len(body) < content_length:
                chunk = upstream.recv(65536)
                if not chunk:
                    break
                body += chunk
            body = body[:content_length]
        elif b"transfer-encoding: chunked" in lower:
            # Rare for CDP; fall back to short drain.
            upstream.settimeout(0.2)
            try:
                while True:
                    chunk = upstream.recv(65536)
                    if not chunk:
                        break
                    body += chunk
            except OSError:
                pass
        else:
            upstream.settimeout(0.2)
            try:
                while True:
                    chunk = upstream.recv(65536)
                    if not chunk:
                        break
                    body += chunk
            except OSError:
                pass

        if b"application/json" in lower or body.lstrip().startswith((b"{", b"[")):
            new_body = rewrite_json_urls(body, public_host, public_port, internal_port)
            if new_body != body:
                body = new_body
                # Refresh Content-Length.
                resp_headers = re.sub(
                    rb"(?im)^content-length:\s*\d+(\r?\n)",
                    f"Content-Length: {len(body)}".encode() + rb"\1",
                    resp_headers,
                    count=1,
                )
                if not re.search(rb"(?im)^content-length:", resp_headers):
                    nl = b"\r\n" if b"\r\n" in resp_headers else b"\n"
                    resp_headers = resp_headers[:-len(nl)*2] + (
                        nl + f"Content-Length: {len(body)}".encode() + nl + nl
                    )

        client.sendall(resp_headers + body)
        # Keep-alive not required for CDP clients; close.
    except OSError as exc:
        sys.stderr.write(f"[cdp-host-proxy] client error: {exc}\n")
    finally:
        for s in (client, upstream):
            if s is None:
                continue
            try:
                s.close()
            except OSError:
                pass


def serve(public_port: int, internal_port: int, bind: str) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((bind, public_port))
    srv.listen(100)
    sys.stderr.write(
        f"[cdp-host-proxy] {bind}:{public_port} -> 127.0.0.1:{internal_port}\n"
    )
    while True:
        client, _ = srv.accept()
        threading.Thread(
            target=handle_client,
            args=(client, internal_port, public_port),
            daemon=True,
        ).start()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--public-port",
        type=int,
        default=int(os.environ.get("CHROME_REMOTE_DEBUGGING_PORT", "9223")),
    )
    parser.add_argument(
        "--internal-port",
        type=int,
        default=int(os.environ.get("CHROME_CDP_INTERNAL_PORT", "19223")),
    )
    parser.add_argument("--bind", default="0.0.0.0")
    args = parser.parse_args()
    if args.public_port == args.internal_port:
        print("public and internal ports must differ", file=sys.stderr)
        sys.exit(2)
    serve(args.public_port, args.internal_port, args.bind)


if __name__ == "__main__":
    main()
