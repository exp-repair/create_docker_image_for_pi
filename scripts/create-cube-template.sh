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

# Space- or comma-separated CIDRs to allow at template network level, e.g.:
#   ALLOW_OUT_CIDRS="10.110.158.143/32 1.2.3.4/32" scripts/create-cube-template.sh
ALLOW_OUT_CIDRS="${ALLOW_OUT_CIDRS:-}"

log() { echo "[create-cube-template] $*"; }
die() { echo "[create-cube-template] ERROR: $*" >&2; exit 1; }

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
test -x /usr/local/bin/configure-multica-runtime.sh
test -x /entrypoint-multica-daemon.sh
test -x /usr/local/bin/multica
command -v pi >/dev/null 2>&1 || test -x /home/user/.npm-global/bin/pi
'

docker inspect "${SOURCE_IMAGE}" --format '[create-cube-template] image={{.Id}} entrypoint={{json .Config.Entrypoint}} workdir={{.Config.WorkingDir}}'

allow_args=()
if [[ -n "${ALLOW_OUT_CIDRS}" ]]; then
  normalized_cidrs="${ALLOW_OUT_CIDRS//,/ }"
  for cidr in ${normalized_cidrs}; do
    [[ -n "${cidr}" ]] && allow_args+=(--allow-out-cidr "${cidr}")
  done
fi

create_args=(
  template create-from-image
  --image "${SOURCE_IMAGE}"
  --writable-layer-size "${WRITABLE_LAYER_SIZE}"
  --expose-port 5901
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
  --env 'VNC_PORT=5901'
  --env 'NOVNC_PORT=6080'
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

cat > "${OUTPUT_ENV_FILE}" <<EOF
CUBE_TEMPLATE_ID=${CUBE_TEMPLATE_ID}
CUBE_TEMPLATE_JOB_ID=${CUBE_TEMPLATE_JOB_ID}
SOURCE_IMAGE=${SOURCE_IMAGE}
EOF

log "wrote ${OUTPUT_ENV_FILE}"
echo "CUBE_TEMPLATE_ID=${CUBE_TEMPLATE_ID}"
echo "CUBE_TEMPLATE_JOB_ID=${CUBE_TEMPLATE_JOB_ID}"
