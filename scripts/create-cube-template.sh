#!/usr/bin/env bash
# Convert a Docker image built by this repo into a Cube sandbox template.
# TEAM_* and MULTICA_* credentials are intentionally not baked into the template;
# inject them later with scripts/create-runtime-sandbox.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE_IMAGE="${SOURCE_IMAGE:-cube-leagent-template:local}"
CUBEMASTER_CLI="${CUBEMASTER_CLI:-/usr/local/services/cubetoolbox/CubeMaster/bin/cubemastercli}"
WRITABLE_LAYER_SIZE="${WRITABLE_LAYER_SIZE:-10G}"
PROBE_PORT="${PROBE_PORT:-49999}"
PROBE_PATH="${PROBE_PATH:-/health}"
WATCH_TEMPLATE="${WATCH_TEMPLATE:-1}"
OUTPUT_ENV_FILE="${OUTPUT_ENV_FILE:-.cube-template.env}"
PI_CONFIG="${PI_CONFIG:-config/pi.env}"

log() { echo "[create-cube-template] $*"; }
die() { echo "[create-cube-template] ERROR: $*" >&2; exit 1; }

# Let config/pi.env provide non-secret template defaults such as sandbox proxy.
# Command-line environment variables still take priority over config values.
ENV_HOST_IP="${HOST_IP:-}"
ENV_CUBE_DEV_GATEWAY="${CUBE_DEV_GATEWAY:-}"
ENV_ALLOW_OUT_CIDRS="${ALLOW_OUT_CIDRS:-}"
ENV_HOST_PROXY_PORT="${HOST_PROXY_PORT:-}"
ENV_ENABLE_SANDBOX_HOST_PROXY="${ENABLE_SANDBOX_HOST_PROXY:-}"
ENV_SANDBOX_PROXY_URL="${SANDBOX_PROXY_URL:-}"
ENV_SANDBOX_NO_PROXY="${SANDBOX_NO_PROXY:-}"
if [[ -f "${PI_CONFIG}" ]]; then
  # shellcheck disable=SC1090
  source "${PI_CONFIG}"
  log "loaded template config from ${PI_CONFIG}"
fi

# Space- or comma-separated CIDRs to allow at template network level.
# Default: cube-dev gateway (192.168.0.1) + primary host IP.
# Override: ALLOW_OUT_CIDRS="192.168.0.1/32 10.110.158.143/32" scripts/create-cube-template.sh
HOST_IP="${ENV_HOST_IP:-${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}}"
CUBE_DEV_GATEWAY="${ENV_CUBE_DEV_GATEWAY:-${CUBE_DEV_GATEWAY:-192.168.0.1}}"
ALLOW_OUT_CIDRS="${ENV_ALLOW_OUT_CIDRS:-${ALLOW_OUT_CIDRS:-${CUBE_DEV_GATEWAY}/32 ${HOST_IP}/32}}"
HOST_PROXY_PORT="${ENV_HOST_PROXY_PORT:-${HOST_PROXY_PORT:-7893}}"
ENABLE_SANDBOX_HOST_PROXY="${ENV_ENABLE_SANDBOX_HOST_PROXY:-${ENABLE_SANDBOX_HOST_PROXY:-0}}"
SANDBOX_PROXY_URL="${ENV_SANDBOX_PROXY_URL:-${SANDBOX_PROXY_URL:-}}"
SANDBOX_NO_PROXY="${ENV_SANDBOX_NO_PROXY:-${SANDBOX_NO_PROXY:-localhost,127.0.0.1,::1,${HOST_IP},${CUBE_DEV_GATEWAY},10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local}}"
LENOVO_MODELFACTORY_HOST="${LENOVO_MODELFACTORY_HOST:-modelfactory.lenovo.com}"
LENOVO_MODELFACTORY_IP="${LENOVO_MODELFACTORY_IP:-10.110.158.101}"

# Always allow ModelFactory so Multica sandboxes can reach DeepSeek without extra config.
case " ${ALLOW_OUT_CIDRS} " in
  *" ${LENOVO_MODELFACTORY_IP}/32 "*|*" ${LENOVO_MODELFACTORY_IP} "*) ;;
  *) ALLOW_OUT_CIDRS="${ALLOW_OUT_CIDRS} ${LENOVO_MODELFACTORY_IP}/32" ;;
esac
case ",${SANDBOX_NO_PROXY}," in
  *",${LENOVO_MODELFACTORY_HOST},"*) ;;
  *) SANDBOX_NO_PROXY="${SANDBOX_NO_PROXY},${LENOVO_MODELFACTORY_HOST}" ;;
esac
case ",${SANDBOX_NO_PROXY}," in
  *",${LENOVO_MODELFACTORY_IP},"*) ;;
  *) SANDBOX_NO_PROXY="${SANDBOX_NO_PROXY},${LENOVO_MODELFACTORY_IP}" ;;
esac

if [[ -z "${SANDBOX_PROXY_URL}" && "${ENABLE_SANDBOX_HOST_PROXY}" == "1" ]]; then
  SANDBOX_PROXY_URL="http://${HOST_IP}:${HOST_PROXY_PORT}"
fi

command -v docker >/dev/null 2>&1 || die "docker is required"
[[ -x "${CUBEMASTER_CLI}" ]] || die "cubemastercli not found or not executable: ${CUBEMASTER_CLI}"
docker image inspect "${SOURCE_IMAGE}" >/dev/null 2>&1 || die "source image not found: ${SOURCE_IMAGE}"

log "source image: ${SOURCE_IMAGE}"
log "checking image has built-in Cube/Multica runtime helpers"
docker run --rm --entrypoint /bin/sh "${SOURCE_IMAGE}" -lc '
set -eu
test -x /usr/local/bin/cube-start.sh
test -x /usr/local/bin/start-multica-runtime.sh
test -x /usr/local/bin/configure-pi-runtime.sh
test -x /usr/local/bin/configure-cursor-runtime.sh
test -x /usr/local/bin/configure-multica-runtime.sh
test -x /entrypoint-multica-daemon.sh
test -x /entrypoint-pi-web.sh
test -x /usr/local/bin/multica
test -f /opt/pi-web/server.js
test -f /root/.pi/agent/models.json
test -f /root/.pi/agent/settings.json
grep -q "lenovo-deepseek-v4-flash" /root/.pi/agent/models.json
grep -q "DeepSeek-V4-Flash-0731" /root/.pi/agent/settings.json
command -v pi >/dev/null 2>&1 || test -x /root/.npm-global/bin/pi
command -v cursor-agent >/dev/null 2>&1 || test -x /usr/local/bin/cursor-agent || test -x /root/.local/bin/cursor-agent
! id user >/dev/null 2>&1
'

docker inspect "${SOURCE_IMAGE}" --format '[create-cube-template] image={{.Id}} entrypoint={{json .Config.Entrypoint}} workdir={{.Config.WorkingDir}}'

allow_args=()
if [[ -n "${ALLOW_OUT_CIDRS}" ]]; then
  normalized_cidrs="${ALLOW_OUT_CIDRS//,/ }"
  for cidr in ${normalized_cidrs}; do
    [[ -n "${cidr}" ]] && allow_args+=(--allow-out-cidr "${cidr}")
  done
  log "egress allow-out-cidr: ${ALLOW_OUT_CIDRS}"
else
  log "WARN: ALLOW_OUT_CIDRS is empty; sandboxes cannot reach host services by IP"
fi

proxy_env_args=()
if [[ -n "${SANDBOX_PROXY_URL}" ]]; then
  proxy_env_args+=(
    --env "HTTP_PROXY=${SANDBOX_PROXY_URL}"
    --env "HTTPS_PROXY=${SANDBOX_PROXY_URL}"
    --env "ALL_PROXY=${SANDBOX_PROXY_URL}"
    --env "http_proxy=${SANDBOX_PROXY_URL}"
    --env "https_proxy=${SANDBOX_PROXY_URL}"
    --env "all_proxy=${SANDBOX_PROXY_URL}"
    --env "NO_PROXY=${SANDBOX_NO_PROXY}"
    --env "no_proxy=${SANDBOX_NO_PROXY}"
  )
  log "sandbox proxy: ${SANDBOX_PROXY_URL}"
  log "sandbox no_proxy: ${SANDBOX_NO_PROXY}"
fi

create_args=(
  template create-from-image
  --image "${SOURCE_IMAGE}"
  --writable-layer-size "${WRITABLE_LAYER_SIZE}"
  # --expose-port 5901  # Cube 最多 3 个 expose-port；暂时不对外暴露 VNC
  --expose-port 6079
  --expose-port 6080
  --expose-port 9223
  --probe "${PROBE_PORT}"
  --probe-path "${PROBE_PATH}"
  --cmd /usr/local/bin/cube-start.sh
  --env 'DISPLAY=:0'
  --env 'SCREEN_GEOM=1920x1080x24'
  --env 'RESOLUTION=1920x1080x24'
  --env 'RESOLUTION_WIDTH=1920'
  --env 'RESOLUTION_HEIGHT=1080'
  # --env 'VNC_PORT=5901'
  --env 'NOVNC_PORT=6080'
  --env 'PI_WEB_HOST=0.0.0.0'
  --env 'PI_WEB_PORT=6079'
  --env 'PI_WEB_WORKSPACE=/workspace'
  --env "LENOVO_MODELFACTORY_HOST=${LENOVO_MODELFACTORY_HOST}"
  --env "LENOVO_MODELFACTORY_IP=${LENOVO_MODELFACTORY_IP}"
  --env 'NODE_EXTRA_CA_CERTS=/root/.pi/agent/certs/lenovo-modelfactory-ca.pem'
  --env 'NODE_OPTIONS=--require=/usr/local/lib/lenovo-modelfactory-dns-hook.js'
  "${proxy_env_args[@]}"
  "${allow_args[@]}"
  --json
)

log "creating Cube template"
CREATE_OUTPUT=$("${CUBEMASTER_CLI}" "${create_args[@]}")
printf '%s\n' "${CREATE_OUTPUT}" > /tmp/cube-template-create.json

read -r CUBE_TEMPLATE_JOB_ID CUBE_TEMPLATE_ID < <(python3 - <<'PY'
import json
with open('/tmp/cube-template-create.json') as f:
    data = json.load(f)
job = data.get('job') or {}
print(job.get('job_id', ''), job.get('template_id', ''))
PY
)

[[ -n "${CUBE_TEMPLATE_JOB_ID}" ]] || die "could not parse job_id from create response: ${CREATE_OUTPUT}"
[[ -n "${CUBE_TEMPLATE_ID}" ]] || die "could not parse template_id from create response: ${CREATE_OUTPUT}"

log "job: ${CUBE_TEMPLATE_JOB_ID}"
log "template: ${CUBE_TEMPLATE_ID}"

if [[ "${WATCH_TEMPLATE}" == "1" ]]; then
  log "waiting for template build to finish"
  "${CUBEMASTER_CLI}" template watch --job-id "${CUBE_TEMPLATE_JOB_ID}" --interval 5s --json
fi

{
  cat <<EOF
CUBE_TEMPLATE_ID=${CUBE_TEMPLATE_ID}
CUBE_TEMPLATE_JOB_ID=${CUBE_TEMPLATE_JOB_ID}
SOURCE_IMAGE=${SOURCE_IMAGE}
ALLOW_OUT_CIDRS="${ALLOW_OUT_CIDRS}"
EOF
  if [[ -n "${SANDBOX_PROXY_URL}" ]]; then
    printf 'SANDBOX_PROXY_URL="%s"\n' "${SANDBOX_PROXY_URL}"
    printf 'SANDBOX_NO_PROXY="%s"\n' "${SANDBOX_NO_PROXY}"
  fi
} > "${OUTPUT_ENV_FILE}"

log "wrote ${OUTPUT_ENV_FILE}"
echo "CUBE_TEMPLATE_ID=${CUBE_TEMPLATE_ID}"
echo "CUBE_TEMPLATE_JOB_ID=${CUBE_TEMPLATE_JOB_ID}"
