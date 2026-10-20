#!/usr/bin/env bash
# Run the test/alpha Cube sandbox image built by scripts/build-test.sh.
# Independent of scripts/run.sh: different image, container name, and host ports.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-cube-leagent-template-test:local}"
PROJECT_NAME="${PROJECT_NAME:-$(basename "$(pwd)")}"
NAME="${NAME:-${PROJECT_NAME}-cube-leagent-test}"
if [[ -z "${PI_CONFIG:-}" ]]; then
  if [[ -f config/pi-test.env ]]; then
    PI_CONFIG=config/pi-test.env
  else
    PI_CONFIG=config/pi.env
  fi
fi
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
  echo "[run-test.sh] loaded runtime Pi config from ${PI_CONFIG}"
fi

# Offset from scripts/run.sh so production and test containers can run together.
PI_WEB_HOST_PORT="${PI_WEB_HOST_PORT:-27079}"
NOVNC_HOST_PORT="${NOVNC_HOST_PORT:-27080}"
VNC_HOST_PORT="${VNC_HOST_PORT:-26901}"
ENVD_HOST_PORT="${ENVD_HOST_PORT:-25983}"
CODE_API_HOST_PORT="${CODE_API_HOST_PORT:-25999}"
LENOVO_MODELFACTORY_HOST="${LENOVO_MODELFACTORY_HOST:-modelfactory.lenovo.com}"
LENOVO_MODELFACTORY_IP="${LENOVO_MODELFACTORY_IP:-10.110.158.101}"
SANDBOX_NO_PROXY="${SANDBOX_NO_PROXY:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
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

# Test Computer environment: preview/alpha packages + Tencent Cloud test origin.
# Official leagent.me URLs from pi.env must not leak into this container.
MULTICA_ENVIRONMENT="${MULTICA_ENVIRONMENT:-test}"
MULTICA_TEST_SERVER_URL="${MULTICA_TEST_SERVER_URL:-https://82.157.184.89}"
MULTICA_TEST_APP_URL="${MULTICA_TEST_APP_URL:-${MULTICA_TEST_SERVER_URL}}"
is_official_cloud_url() {
  local host
  host="$(printf '%s' "${1:-}" | sed -E 's#^https?://##' | cut -d/ -f1 | cut -d: -f1 | tr '[:upper:]' '[:lower:]')"
  case "${host}" in
    leagent.me|www.leagent.me|api.leagent.me) return 0 ;;
    *) return 1 ;;
  esac
}
if [[ "${MULTICA_ENVIRONMENT}" == "test" ]]; then
  if [[ -z "${MULTICA_SERVER_URL:-}" ]] || is_official_cloud_url "${MULTICA_SERVER_URL}"; then
    MULTICA_SERVER_URL="${MULTICA_TEST_SERVER_URL}"
  fi
  if [[ -z "${MULTICA_APP_URL:-}" ]] || is_official_cloud_url "${MULTICA_APP_URL}"; then
    MULTICA_APP_URL="${MULTICA_TEST_APP_URL}"
  fi
  test_api_host="$(printf '%s' "${MULTICA_SERVER_URL}" | sed -E 's#^https?://##' | cut -d/ -f1 | cut -d: -f1)"
  test_app_host="$(printf '%s' "${MULTICA_APP_URL}" | sed -E 's#^https?://##' | cut -d/ -f1 | cut -d: -f1)"
  for test_host in "${test_api_host}" "${test_app_host}" cdn.leagent.me; do
    [[ -n "${test_host}" ]] || continue
    case ",${SANDBOX_NO_PROXY}," in
      *",${test_host},"*) ;;
      *) SANDBOX_NO_PROXY="${SANDBOX_NO_PROXY},${test_host}" ;;
    esac
  done
  echo "[run-test.sh] Multica test environment server=${MULTICA_SERVER_URL} app=${MULTICA_APP_URL}"
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

if [[ -n "${LENOVO_MODELFACTORY_HOST}" && -n "${LENOVO_MODELFACTORY_IP}" ]]; then
  DOCKER_EXTRA_ARGS+=(--add-host="${LENOVO_MODELFACTORY_HOST}:${LENOVO_MODELFACTORY_IP}")
fi

if ! ${DOCKER_BIN} image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "[run-test.sh] ERROR: test image not found: ${IMAGE}" >&2
  echo "[run-test.sh] hint: ./scripts/build-test.sh" >&2
  exit 1
fi

echo "[run-test.sh] replacing managed test container if it exists: ${NAME}"
${DOCKER_BIN} rm -f "${NAME}" >/dev/null 2>&1 || true

echo "[run-test.sh] starting ${NAME} from ${IMAGE} ..."
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
  -e LENOVO_DEEPSEEK_PROVIDER="${LENOVO_DEEPSEEK_PROVIDER:-openai}" \
  -e LENOVO_DEEPSEEK_MODEL="${LENOVO_DEEPSEEK_MODEL:-DeepSeek}" \
  -e LENOVO_DEEPSEEK_BASE_URL="${LENOVO_DEEPSEEK_BASE_URL:-https://modelfactory.lenovo.com/llm/v1}" \
  -e LENOVO_MODELFACTORY_HOST="${LENOVO_MODELFACTORY_HOST}" \
  -e LENOVO_MODELFACTORY_IP="${LENOVO_MODELFACTORY_IP}" \
  -e NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-/root/.pi/agent/certs/lenovo-modelfactory-ca.pem}" \
  ${MULTICA_SERVER_URL:+-e MULTICA_SERVER_URL="${MULTICA_SERVER_URL}"} \
  ${MULTICA_APP_URL:+-e MULTICA_APP_URL="${MULTICA_APP_URL}"} \
  ${MULTICA_WORKSPACE_ID:+-e MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID}"} \
  ${MULTICA_TOKEN:+-e MULTICA_TOKEN="${MULTICA_TOKEN}"} \
  ${MULTICA_PROFILE:+-e MULTICA_PROFILE="${MULTICA_PROFILE}"} \
  -e MULTICA_ENVIRONMENT="${MULTICA_ENVIRONMENT:-test}" \
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

echo "[run-test.sh] ensuring VNC stack ..."
if ${DOCKER_BIN} exec "${NAME}" test -x /etc/cont-init.d/99-browser-vnc 2>/dev/null; then
  ${DOCKER_BIN} exec "${NAME}" /etc/cont-init.d/99-browser-vnc || true
fi

sleep 2

echo "[run-test.sh] ensuring Multica daemon ..."
if ${DOCKER_BIN} exec "${NAME}" test -x /entrypoint-multica-daemon.sh 2>/dev/null \
  && ${DOCKER_BIN} exec "${NAME}" sh -lc 'test -n "$MULTICA_SERVER_URL" && test -n "$MULTICA_APP_URL" && test -n "$MULTICA_WORKSPACE_ID" && test -n "$MULTICA_TOKEN"' 2>/dev/null; then
  if ! ${DOCKER_BIN} exec "${NAME}" sh -lc \
    'pgrep -f "multica.*daemon supervise" >/dev/null 2>&1 \
      || pgrep -f "multica.*computer supervise" >/dev/null 2>&1 \
      || pgrep -f "multica.*daemon start --foreground" >/dev/null 2>&1 \
      || pgrep -f "multica.*computer start --foreground" >/dev/null 2>&1 \
      || pgrep -f "/entrypoint-multica-daemon\\.sh" >/dev/null 2>&1'; then
    ${DOCKER_BIN} exec -d "${NAME}" /entrypoint-multica-daemon.sh || true
  fi
fi

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
echo ""
echo "=========================================="
echo "  TEST image: ${IMAGE}"
echo "  container:  ${NAME}"
echo "  Pi Web: http://${HOST_IP}:${PI_WEB_HOST_PORT}/"
echo "  Term:   http://${HOST_IP}:${PI_WEB_HOST_PORT}/term"
echo "  noVNC:  http://${HOST_IP}:${NOVNC_HOST_PORT}/"
echo "  VNC:    ${HOST_IP}:${VNC_HOST_PORT}"
echo "  envd:   ${HOST_IP}:${ENVD_HOST_PORT}"
echo "  code:   ${HOST_IP}:${CODE_API_HOST_PORT}"
echo "  logs:   ${DOCKER_BIN} logs -f ${NAME}"
echo "  shell:  ${DOCKER_BIN} exec -it ${NAME} bash"
echo "  diag:   IMAGE=${IMAGE} ./scripts/diagnose.sh"
echo "=========================================="
