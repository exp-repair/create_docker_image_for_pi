#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-cube-leagent-template:local}"
NAME="${NAME:-cube-leagent}"

OLD_IDS=$(sudo docker ps -aq --filter "ancestor=${IMAGE}" 2>/dev/null || true)
if [[ -n "${OLD_IDS}" ]]; then
  echo "[run.sh] stopping old containers: ${OLD_IDS}"
  sudo docker rm -f ${OLD_IDS} >/dev/null 2>&1 || true
fi
sudo docker rm -f "${NAME}" >/dev/null 2>&1 || true

echo "[run.sh] starting ${NAME} ..."
sudo docker run -d --name "${NAME}" \
  -p 6080:6080 -p 5901:5901 \
  -p 49983:49983 -p 49999:49999 \
  -e DISPLAY=":0" \
  -e SCREEN_GEOM="${SCREEN_GEOM:-1920x1080x24}" \
  -e VNC_PORT="${VNC_PORT:-5901}" \
  -e NOVNC_PORT="${NOVNC_PORT:-6080}" \
  ${VNC_PASSWORD:+-e VNC_PASSWORD="${VNC_PASSWORD}"} \
  --shm-size=2g \
  "${IMAGE}" "$@"

sleep 5

echo "[run.sh] ensuring VNC stack ..."
if sudo docker exec "${NAME}" test -x /etc/cont-init.d/99-browser-vnc 2>/dev/null; then
  sudo docker exec "${NAME}" /etc/cont-init.d/99-browser-vnc || true
fi

sleep 2
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
echo ""
echo "=========================================="
echo "  noVNC:  http://${HOST_IP}:6080/"
echo "  VNC:    ${HOST_IP}:5901"
echo "  logs:   sudo docker logs -f ${NAME}"
echo "  shell:  sudo docker exec -it ${NAME} bash"
echo "=========================================="
