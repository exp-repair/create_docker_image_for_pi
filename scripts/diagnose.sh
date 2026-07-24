#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-cube-leagent-template:local}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
CID="${1:-$(${DOCKER_BIN} ps -q --filter ancestor="${IMAGE}" | head -1)}"
if [[ -z "${CID}" ]]; then
  echo "No running container for image ${IMAGE}"
  echo "Usage: ./scripts/diagnose.sh [container-id]"
  exit 1
fi

echo "=== container ${CID} ==="
${DOCKER_BIN} ps --filter "id=${CID}"

echo ""
echo "=== port mappings ==="
${DOCKER_BIN} port "${CID}" || true

echo ""
echo "=== processes (Cube API / Xvfb / VNC / Chromium / Pi / Multica) ==="
${DOCKER_BIN} exec "${CID}" sh -c \
  'ps aux | grep -E "uvicorn|envd|Xvfb|x11vnc|websockify|chromium|entrypoint-vnc|pi-web|server.js|multica" | grep -v grep || echo "(none)"'

echo ""
echo "=== listening ports ==="
${DOCKER_BIN} exec "${CID}" sh -c \
  'ss -tlnp 2>/dev/null | grep -E "5901|6079|6080|9223|49983|49999" || true'

echo ""
echo "=== key paths and binaries ==="
${DOCKER_BIN} exec "${CID}" sh -c \
  'ls -la /workspace /workspace/uploads /workspace/browser-shots /data/browser-profile 2>&1; \
   for c in python3 node npm chromium rg fd pi multica Xvfb x11vnc websockify openbox; do printf "%s=" "$c"; command -v "$c" || true; done; \
   pi --version 2>/dev/null || true; \
   multica version 2>/dev/null || true'

echo ""
echo "=== in-container HTTP checks ==="
${DOCKER_BIN} exec "${CID}" sh -c \
  'python3 - <<"PY"
import urllib.request
for url in ("http://127.0.0.1:49999/health", "http://127.0.0.1:6080/", "http://127.0.0.1:6079/"):
    try:
        with urllib.request.urlopen(url, timeout=3) as r:
            print(f"{url} => {r.status}")
    except Exception as exc:
        print(f"{url} => ERR {type(exc).__name__}: {exc}")
PY'

echo ""
echo "=== host HTTP checks ==="
curl -sS -o /dev/null -w "6079/ => %{http_code}\n" --connect-timeout 3 http://127.0.0.1:${PI_WEB_HOST_PORT:-6079}/ || true
curl -sS -o /dev/null -w "6080/ => %{http_code}\n" --connect-timeout 3 http://127.0.0.1:6080/ || true
curl -sS -o /dev/null -w "49999/health => %{http_code}\n" --connect-timeout 3 http://127.0.0.1:49999/health || true
