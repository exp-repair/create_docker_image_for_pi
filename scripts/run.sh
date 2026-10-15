#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-coforge-pi:local}"
NAME="${NAME:-coforge-pi}"
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

# Host publish port for the web terminal.
# Applied after pi.env so unset values get this default; explicit env still wins.
PI_WEB_HOST_PORT="${PI_WEB_HOST_PORT:-26079}"
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
# The bundled Computer binary talks to CoForge on the host loopback, so the
# container joins the host network instead of publishing a bridge port.
${DOCKER_BIN} run -d --name "${NAME}" \
  --network host \
  -e PI_WEB_HOST="0.0.0.0" \
  -e PI_WEB_PORT="${PI_WEB_HOST_PORT}" \
  -e COFORGE_WORKSPACE_SLUG="${COFORGE_WORKSPACE_SLUG:-my}" \
  -e PI_WEB_WORKSPACE="${PI_WORKSPACE_DIR:-/workspace}" \
  -e PI_WEB_CONSOLE="0" \
  -e PI_WEB_TERM_SHELL="${PI_WEB_TERM_SHELL:-/bin/bash}" \
  ${PI_WEB_TERM_TOKEN:+-e PI_WEB_TERM_TOKEN="${PI_WEB_TERM_TOKEN}"} \
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
  "${DOCKER_EXTRA_ARGS[@]}" \
  "${IMAGE}" "$@"

sleep 2

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
echo ""
echo "=========================================="
echo "  Term:   http://${HOST_IP}:${PI_WEB_HOST_PORT}/term"
echo "  logs:   ${DOCKER_BIN} logs -f ${NAME}"
echo "  shell:  ${DOCKER_BIN} exec -it ${NAME} bash"
echo "=========================================="
