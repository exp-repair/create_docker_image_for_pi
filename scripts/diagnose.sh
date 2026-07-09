#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-cube-leagent-template:local}"
CID="${1:-$(sudo docker ps -q --filter ancestor="${IMAGE}" | head -1)}"
if [[ -z "${CID}" ]]; then
  echo "No running container for image ${IMAGE}"
  echo "Usage: ./scripts/diagnose.sh [container-id]"
  exit 1
fi

echo "=== container ${CID} ==="
sudo docker ps --filter "id=${CID}"

echo ""
echo "=== port mappings ==="
sudo docker port "${CID}"

echo ""
echo "=== processes (Xvfb / vnc / websockify / pi-web) ==="
sudo docker exec "${CID}" sh -c \
  'ps aux | grep -E "Xvfb|x11vnc|websockify|entrypoint-vnc|pi-web|server.js" | grep -v grep || echo "(none)"'

echo ""
echo "=== listening ports ==="
sudo docker exec "${CID}" sh -c \
  'ss -tlnp 2>/dev/null | grep -E "5901|6079|6080|9223|49983|49999" || netstat -tlnp 2>/dev/null | grep -E "5901|6079|6080|9223|49983|49999" || true'

echo ""
echo "=== Leagent paths ==="
sudo docker exec "${CID}" sh -c \
  'ls -la /workspace /workspace/uploads /workspace/browser-shots 2>&1; \
   command -v chromium rg tmux git wget 2>/dev/null; true'

echo ""
echo "=== s6 registration ==="
sudo docker exec "${CID}" sh -c \
  'find /etc/s6-overlay/s6-rc.d -path "*/contents.d/*" -print 2>/dev/null | sort'

echo ""
echo "=== host curl ==="
curl -sS -o /dev/null -w "6079/ => %{http_code}\n" --connect-timeout 3 http://127.0.0.1:${PI_WEB_HOST_PORT:-6079}/ || true
curl -sS -o /dev/null -w "6080/ => %{http_code}\n" --connect-timeout 3 http://127.0.0.1:6080/ || true
curl -sS -o /dev/null -w "49999/ => %{http_code}\n" --connect-timeout 3 http://127.0.0.1:49999/ || true
