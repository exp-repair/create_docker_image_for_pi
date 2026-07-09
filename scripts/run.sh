#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-cube-leagent-template:local}"
NAME="${NAME:-cube-leagent}"
PI_CONFIG="${PI_CONFIG:-config/pi.env}"

if [[ -f "${PI_CONFIG}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${PI_CONFIG}"
  set +a
  echo "[run.sh] loaded runtime Pi config from ${PI_CONFIG}"
fi

OLD_IDS=$(sudo docker ps -aq --filter "ancestor=${IMAGE}" 2>/dev/null || true)
if [[ -n "${OLD_IDS}" ]]; then
  echo "[run.sh] stopping old containers: ${OLD_IDS}"
  sudo docker rm -f ${OLD_IDS} >/dev/null 2>&1 || true
fi
sudo docker rm -f "${NAME}" >/dev/null 2>&1 || true

echo "[run.sh] starting ${NAME} ..."
sudo docker run -d --name "${NAME}" \
  -p ${PI_WEB_HOST_PORT:-6079}:6079 \
  -p 6080:6080 -p 5901:5901 \
  -p 49983:49983 -p 49999:49999 \
  -e DISPLAY=":0" \
  -e SCREEN_GEOM="${SCREEN_GEOM:-1920x1080x24}" \
  -e VNC_PORT="${VNC_PORT:-5901}" \
  -e NOVNC_PORT="${NOVNC_PORT:-6080}" \
  -e PI_WEB_HOST="0.0.0.0" \
  -e PI_WEB_PORT="6079" \
  -e PI_WEB_WORKSPACE="${PI_WORKSPACE_DIR:-/workspace}" \
  ${VNC_PASSWORD:+-e VNC_PASSWORD="${VNC_PASSWORD}"} \
  ${TEAM_API_KEY:+-e TEAM_API_KEY="${TEAM_API_KEY}"} \
  -e TEAM_BASE_URL="${TEAM_BASE_URL:-https://claude-code.club/openai/v1}" \
  -e TEAM_MODEL="${TEAM_MODEL:-gpt-5.5}" \
  ${BRIDGE_USER_ID:+-e BRIDGE_USER_ID="${BRIDGE_USER_ID}"} \
  ${AREAL_BASE_URL:+-e AREAL_BASE_URL="${AREAL_BASE_URL}"} \
  ${AREAL_API:+-e AREAL_API="${AREAL_API}"} \
  ${AREAL_API_KEY:+-e AREAL_API_KEY="${AREAL_API_KEY}"} \
  ${MULTICA_SERVER_URL:+-e MULTICA_SERVER_URL="${MULTICA_SERVER_URL}"} \
  ${MULTICA_APP_URL:+-e MULTICA_APP_URL="${MULTICA_APP_URL}"} \
  ${MULTICA_WORKSPACE_ID:+-e MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID}"} \
  ${MULTICA_TOKEN:+-e MULTICA_TOKEN="${MULTICA_TOKEN}"} \
  ${MULTICA_PROFILE:+-e MULTICA_PROFILE="${MULTICA_PROFILE}"} \
  -e MULTICA_DAEMON_ENABLED="${MULTICA_DAEMON_ENABLED:-1}" \
  --shm-size=2g \
  "${IMAGE}" "$@"

sleep 5

echo "[run.sh] ensuring VNC stack ..."
if sudo docker exec "${NAME}" test -x /etc/cont-init.d/99-browser-vnc 2>/dev/null; then
  sudo docker exec "${NAME}" /etc/cont-init.d/99-browser-vnc || true
fi

sleep 2

echo "[run.sh] ensuring Multica daemon ..."
if sudo docker exec "${NAME}" test -x /entrypoint-multica-daemon.sh 2>/dev/null \
  && sudo docker exec "${NAME}" sh -lc 'test -n "$MULTICA_SERVER_URL" && test -n "$MULTICA_APP_URL" && test -n "$MULTICA_WORKSPACE_ID" && test -n "$MULTICA_TOKEN"' 2>/dev/null; then
  if ! sudo docker exec "${NAME}" pgrep -f "multica.*daemon start --foreground" >/dev/null 2>&1; then
    sudo docker exec -d -u user "${NAME}" /entrypoint-multica-daemon.sh || true
  fi
fi

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
echo ""
echo "=========================================="
echo "  Pi Web: http://${HOST_IP}:${PI_WEB_HOST_PORT:-6079}/"
echo "  noVNC:  http://${HOST_IP}:6080/"
echo "  VNC:    ${HOST_IP}:5901"
echo "  logs:   sudo docker logs -f ${NAME}"
echo "  shell:  sudo docker exec -it ${NAME} bash"
echo "=========================================="
