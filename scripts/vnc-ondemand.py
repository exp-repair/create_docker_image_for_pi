#!/usr/bin/env python3
"""Accept VNC on VNC_PORT and start TigerVNC+XFCE only while someone is connected.

The desktop is not running at boot. The first client starts it; after the last
client leaves and VNC_IDLE_SECONDS passes, the desktop exits.
"""
import importlib.util
import os
import secrets
import select
import socket
import subprocess
import threading
import time

LISTEN_PORT = int(os.environ.get("VNC_PORT", "5901"))
BACKEND_PORT = int(os.environ.get("VNC_BACKEND_PORT", "5991"))
IDLE_SECONDS = int(os.environ.get("VNC_IDLE_SECONDS", "600"))
GEOMETRY = os.environ.get("VNC_GEOMETRY", "1920x1080")
DISPLAY = os.environ.get("VNC_DISPLAY", ":1")

clients = 0
last_used = time.time()
server = None
lock = threading.Lock()


def log(message: str) -> None:
    print(f"[vnc] {message}", flush=True)


def write_password() -> None:
    os.makedirs("/root/.vnc", mode=0o700, exist_ok=True)
    password = os.environ.get("VNC_PASSWORD", "").strip()
    if not password:
        password = secrets.token_hex(4)
        path = "/root/.vnc/password.txt"
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(password + "\n")
        os.chmod(path, 0o600)
        log("VNC_PASSWORD is unset; a password was written to /root/.vnc/password.txt")
    # Bookworm's TigerVNC packages ship the server without tigervncpasswd.
    sibling = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vnc-websocket.py")
    spec = importlib.util.spec_from_file_location("vnc_websocket", sibling)
    if spec is None or spec.loader is None:
        raise RuntimeError("vnc-websocket.py is missing")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with open("/root/.vnc/passwd", "wb") as handle:
        handle.write(module.obfuscate_vnc_password(password))
    os.chmod("/root/.vnc/passwd", 0o600)


def port_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), 0.2):
            return True
    except OSError:
        return False


def stop_server() -> None:
    global server
    if server is not None and server.poll() is None:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
    server = None
    subprocess.run(["tigervncserver", "-kill", DISPLAY], check=False, capture_output=True)
    subprocess.run(["pkill", "-f", f"Xtigervnc {DISPLAY}"], check=False)
    for path in (f"/tmp/.X{DISPLAY[1:]}-lock", f"/tmp/.X11-unix/X{DISPLAY[1:]}"):
        try:
            os.remove(path)
        except OSError:
            pass


def start_server() -> None:
    global server
    if port_open(BACKEND_PORT):
        return
    write_password()
    xstartup = "/usr/local/share/coforge/vnc-xstartup"
    if not os.path.exists("/root/.vnc/xstartup"):
        os.makedirs("/root/.vnc", mode=0o700, exist_ok=True)
        os.symlink(xstartup, "/root/.vnc/xstartup")
    server = subprocess.Popen(
        [
            "tigervncserver",
            DISPLAY,
            "-fg",
            "-geometry",
            GEOMETRY,
            "-depth",
            "24",
            "-rfbport",
            str(BACKEND_PORT),
            "-localhost",
            "yes",
            "-rfbauth",
            "/root/.vnc/passwd",
            "-xstartup",
            xstartup,
            "-SecurityTypes",
            "VncAuth",
            "-alwaysshared",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    for _ in range(100):
        if port_open(BACKEND_PORT):
            log(f"desktop started on 127.0.0.1:{BACKEND_PORT}")
            return
        if server.poll() is not None:
            err = server.stderr.read().decode("utf-8", "replace") if server.stderr else ""
            raise RuntimeError(err.strip() or "tigervncserver exited")
        time.sleep(0.1)
    stop_server()
    raise RuntimeError("TigerVNC did not open the backend port")


def splice(left: socket.socket, right: socket.socket) -> None:
    sockets = [left, right]
    try:
        while True:
            readable, _, _ = select.select(sockets, [], [], 60)
            if not readable:
                continue
            for source in readable:
                target = right if source is left else left
                data = source.recv(65536)
                if not data:
                    return
                target.sendall(data)
    finally:
        for item in sockets:
            try:
                item.close()
            except OSError:
                pass


def handle(client: socket.socket) -> None:
    global clients, last_used
    backend = None
    try:
        with lock:
            clients += 1
            start_server()
        backend = socket.create_connection(("127.0.0.1", BACKEND_PORT), 5)
        splice(client, backend)
    except Exception as exc:
        log(f"session failed: {exc}")
        try:
            client.close()
        except OSError:
            pass
    finally:
        with lock:
            clients = max(0, clients - 1)
            last_used = time.time()


def idle_loop() -> None:
    while True:
        time.sleep(5)
        with lock:
            quiet = clients == 0 and time.time() - last_used >= IDLE_SECONDS
        if quiet and port_open(BACKEND_PORT):
            log(f"no clients for {IDLE_SECONDS}s, stopping desktop")
            with lock:
                if clients == 0:
                    stop_server()


def main() -> None:
    threading.Thread(target=idle_loop, daemon=True).start()
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("0.0.0.0", LISTEN_PORT))
    listener.listen(8)
    log(f"listening on :{LISTEN_PORT}; desktop starts on connect")
    while True:
        client, _addr = listener.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
