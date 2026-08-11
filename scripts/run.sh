#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-cube-leagent-template:local}"
PROJECT_NAME="${PROJECT_NAME:-$(basename "$(pwd)")}"
NAME="${NAME:-${PROJECT_NAME}-cube-leagent}"
PI_CONFIG="${PI_CONFIG:-config/pi.env}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
HOST_PROXY_PORT="${HOST_PROXY_PORT:-7893}"
ENABLE_SANDBOX_HOST_PROXY="${ENABLE_SANDBOX_HOST_PROXY:-0}"
SANDBOX_PROXY_URL="${SANDBOX_PROXY_URL:-}"
SANDBOX_NO_PROXY="${SANDBOX_NO_PROXY:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
LENOVO_MODELFACTORY_HOST="${LENOVO_MODELFACTORY_HOST:-modelfactory.lenovo.com}"
LENOVO_MODELFACTORY_IP="${LENOVO_MODELFACTORY_IP:-10.110.158.101}"

if [[ -f "${PI_CONFIG}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${PI_CONFIG}"
  set +a
  echo "[run.sh] loaded runtime Pi config from ${PI_CONFIG}"
fi

# Host publish ports (high/uncommon defaults to avoid clashing with other sandboxes).
# Applied after pi.env so unset values get these defaults; explicit env still wins.
PI_WEB_HOST_PORT="${PI_WEB_HOST_PORT:-26079}"
NOVNC_HOST_PORT="${NOVNC_HOST_PORT:-26080}"
VNC_HOST_PORT="${VNC_HOST_PORT:-25901}"
ENVD_HOST_PORT="${ENVD_HOST_PORT:-24983}"
CODE_API_HOST_PORT="${CODE_API_HOST_PORT:-24999}"
LENOVO_MODELFACTORY_HOST="${LENOVO_MODELFACTORY_HOST:-modelfactory.lenovo.com}"
LENOVO_MODELFACTORY_IP="${LENOVO_MODELFACTORY_IP:-10.110.158.101}"
SANDBOX_NO_PROXY="${SANDBOX_NO_PROXY:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
# Keep ModelFactory off the sandbox HTTP proxy path (intranet TLS endpoint).
case ",${SANDBOX_NO_PROXY}," in
  *",${LENOVO_MODELFACTORY_HOST},"*) ;;
  *) SANDBOX_NO_PROXY="${SANDBOX_NO_PROXY},${LENOVO_MODELFACTORY_HOST}" ;;
esac
case ",${SANDBOX_NO_PROXY}," in
  *",${LENOVO_MODELFACTORY_IP},"*) ;;
  *) SANDBOX_NO_PROXY="${SANDBOX_NO_PROXY},${LENOVO_MODELFACTORY_IP}" ;;
esac
if [[ -z "${SANDBOX_PROXY_URL}" && "${ENABLE_SANDBOX_HOST_PROXY}" == "1" ]]; then
  SANDBOX_PROXY_URL="http://host.docker.internal:${HOST_PROXY_PORT}"
fi

DOCKER_EXTRA_ARGS=()
if [[ -n "${SANDBOX_PROXY_URL}" ]]; then
  DOCKER_EXTRA_ARGS+=(
    -e "HTTP_PROXY=${SANDBOX_PROXY_URL}"
    -e "HTTPS_PROXY=${SANDBOX_PROXY_URL}"
    -e "ALL_PROXY=${SANDBOX_PROXY_URL}"
    -e "http_proxy=${SANDBOX_PROXY_URL}"
    -e "https_proxy=${SANDBOX_PROXY_URL}"
    -e "all_proxy=${SANDBOX_PROXY_URL}"
    -e "NO_PROXY=${SANDBOX_NO_PROXY}"
    -e "no_proxy=${SANDBOX_NO_PROXY}"
  )
  if [[ "${SANDBOX_PROXY_URL}" == *host.docker.internal* ]]; then
    DOCKER_EXTRA_ARGS+=(--add-host=host.docker.internal:host-gateway)
  fi
fi

# Pin Lenovo ModelFactory hostname when cluster DNS is unavailable inside Docker.
if [[ -n "${LENOVO_MODELFACTORY_HOST}" && -n "${LENOVO_MODELFACTORY_IP}" ]]; then
  DOCKER_EXTRA_ARGS+=(--add-host="${LENOVO_MODELFACTORY_HOST}:${LENOVO_MODELFACTORY_IP}")
fi

# Only replace the container managed by this script/name. Do not remove every
# container created from the same image; users may keep other sandboxes around.
echo "[run.sh] replacing managed container if it exists: ${NAME}"
${DOCKER_BIN} rm -f "${NAME}" >/dev/null 2>&1 || true

echo "[run.sh] starting ${NAME} ..."
${DOCKER_BIN} run -d --name "${NAME}" \
  -p "${PI_WEB_HOST_PORT}:6079" \
  -p "${NOVNC_HOST_PORT}:6080" \
  -p "${VNC_HOST_PORT}:5901" \
  -p "${ENVD_HOST_PORT}:49983" \
  -p "${CODE_API_HOST_PORT}:49999" \
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
  -e TEAM_API="${TEAM_API:-openai-responses}" \
  ${TEAM_PROVIDER:+-e TEAM_PROVIDER="${TEAM_PROVIDER}"} \
  ${BRIDGE_USER_ID:+-e BRIDGE_USER_ID="${BRIDGE_USER_ID}"} \
  ${AREAL_BASE_URL:+-e AREAL_BASE_URL="${AREAL_BASE_URL}"} \
  ${AREAL_API:+-e AREAL_API="${AREAL_API}"} \
  ${AREAL_API_KEY:+-e AREAL_API_KEY="${AREAL_API_KEY}"} \
  ${LENOVO_DEEPSEEK_V4_FLASH_API_KEY:+-e LENOVO_DEEPSEEK_V4_FLASH_API_KEY="${LENOVO_DEEPSEEK_V4_FLASH_API_KEY}"} \
  -e LENOVO_DEEPSEEK_AS_DEFAULT="${LENOVO_DEEPSEEK_AS_DEFAULT:-1}" \
  -e LENOVO_DEEPSEEK_PROVIDER="${LENOVO_DEEPSEEK_PROVIDER:-lenovo-deepseek-v4-flash}" \
  -e LENOVO_DEEPSEEK_MODEL="${LENOVO_DEEPSEEK_MODEL:-DeepSeek-V4-Flash-0731}" \
  -e LENOVO_DEEPSEEK_BASE_URL="${LENOVO_DEEPSEEK_BASE_URL:-https://modelfactory.lenovo.com/service-large-600-1777255649450/llm/v1}" \
  -e LENOVO_MODELFACTORY_HOST="${LENOVO_MODELFACTORY_HOST}" \
  -e LENOVO_MODELFACTORY_IP="${LENOVO_MODELFACTORY_IP}" \
  -e NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-/root/.pi/agent/certs/lenovo-modelfactory-ca.pem}" \
  ${MULTICA_SERVER_URL:+-e MULTICA_SERVER_URL="${MULTICA_SERVER_URL}"} \
  ${MULTICA_APP_URL:+-e MULTICA_APP_URL="${MULTICA_APP_URL}"} \
  ${MULTICA_WORKSPACE_ID:+-e MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID}"} \
  ${MULTICA_TOKEN:+-e MULTICA_TOKEN="${MULTICA_TOKEN}"} \
  ${MULTICA_PROFILE:+-e MULTICA_PROFILE="${MULTICA_PROFILE}"} \
  ${CURSOR_API_KEY:+-e CURSOR_API_KEY="${CURSOR_API_KEY}"} \
  ${MULTICA_CURSOR_PATH:+-e MULTICA_CURSOR_PATH="${MULTICA_CURSOR_PATH}"} \
  ${MULTICA_CURSOR_MODEL:+-e MULTICA_CURSOR_MODEL="${MULTICA_CURSOR_MODEL}"} \
  -e MULTICA_DAEMON_ENABLED="${MULTICA_DAEMON_ENABLED:-1}" \
  -e MULTICA_DAEMON_MODE="${MULTICA_DAEMON_MODE:-supervise}" \
  ${MULTICA_DAEMON_SUPERVISE:+-e MULTICA_DAEMON_SUPERVISE="${MULTICA_DAEMON_SUPERVISE}"} \
  "${DOCKER_EXTRA_ARGS[@]}" \
  --shm-size=2g \
  "${IMAGE}" "$@"

sleep 5

echo "[run.sh] ensuring VNC stack ..."
if ${DOCKER_BIN} exec "${NAME}" test -x /etc/cont-init.d/99-browser-vnc 2>/dev/null; then
  ${DOCKER_BIN} exec "${NAME}" /etc/cont-init.d/99-browser-vnc || true
fi

sleep 2

echo "[run.sh] ensuring Multica daemon ..."
if ${DOCKER_BIN} exec "${NAME}" test -x /entrypoint-multica-daemon.sh 2>/dev/null \
  && ${DOCKER_BIN} exec "${NAME}" sh -lc 'test -n "$MULTICA_SERVER_URL" && test -n "$MULTICA_APP_URL" && test -n "$MULTICA_WORKSPACE_ID" && test -n "$MULTICA_TOKEN"' 2>/dev/null; then
  if ! ${DOCKER_BIN} exec "${NAME}" sh -lc \
    'pgrep -f "multica.*daemon supervise" >/dev/null 2>&1 \
      || pgrep -f "multica.*daemon start --foreground" >/dev/null 2>&1 \
      || pgrep -f "/entrypoint-multica-daemon\\.sh" >/dev/null 2>&1'; then
    ${DOCKER_BIN} exec -d "${NAME}" /entrypoint-multica-daemon.sh || true
  fi
fi

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
echo ""
echo "=========================================="
echo "  Pi Web: http://${HOST_IP}:${PI_WEB_HOST_PORT}/"
echo "  Term:   http://${HOST_IP}:${PI_WEB_HOST_PORT}/term"
echo "  noVNC:  http://${HOST_IP}:${NOVNC_HOST_PORT}/"
echo "  VNC:    ${HOST_IP}:${VNC_HOST_PORT}"
echo "  envd:   ${HOST_IP}:${ENVD_HOST_PORT}"
echo "  code:   ${HOST_IP}:${CODE_API_HOST_PORT}"
echo "  logs:   ${DOCKER_BIN} logs -f ${NAME}"
echo "  shell:  ${DOCKER_BIN} exec -it ${NAME} bash"
echo "=========================================="
