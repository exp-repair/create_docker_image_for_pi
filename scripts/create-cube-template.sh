#!/usr/bin/env bash
# Convert a local Docker image into a Cube sandbox template.
# The generated template does NOT bake TEAM_* or MULTICA_* credentials; inject
# them later with scripts/create-runtime-sandbox.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE_IMAGE="${SOURCE_IMAGE:-cube-leagent-template:local}"
CUBE_READY_IMAGE="${CUBE_READY_IMAGE:-cube-leagent-template:multica-dynamic-ready}"
PATCH_CONTAINER="${PATCH_CONTAINER:-cube-template-patch}"
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
[[ -f scripts/start-multica-runtime.sh ]] || die "missing scripts/start-multica-runtime.sh"

docker image inspect "${SOURCE_IMAGE}" >/dev/null 2>&1 || die "source image not found: ${SOURCE_IMAGE}"

log "source image: ${SOURCE_IMAGE}"
log "cube-ready image: ${CUBE_READY_IMAGE}"

cleanup() {
  docker rm -f "${PATCH_CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

log "patching image with Cube startup wrapper and dynamic runtime starter"
docker run -d --name "${PATCH_CONTAINER}" --entrypoint /bin/sh "${SOURCE_IMAGE}" -c 'sleep infinity' >/dev/null

docker cp scripts/start-multica-runtime.sh "${PATCH_CONTAINER}:/usr/local/bin/start-multica-runtime.sh"

docker exec "${PATCH_CONTAINER}" /bin/sh -lc '
set -eu
chmod +x /usr/local/bin/start-multica-runtime.sh

# Make Pi visible to Cube API execution shells even when PATH is minimal.
if [ -x /home/user/.npm-global/bin/pi ]; then
  ln -sf /home/user/.npm-global/bin/pi /usr/local/bin/pi
fi
if [ -x /home/user/.npm-global/bin/pi-mcp-adapter ]; then
  ln -sf /home/user/.npm-global/bin/pi-mcp-adapter /usr/local/bin/pi-mcp-adapter
fi

# Sanity checks. These are expected in the image built by this repo.
test -x /usr/local/bin/multica
test -x /usr/local/bin/configure-pi-runtime.sh
test -x /usr/local/bin/configure-multica-runtime.sh
test -x /entrypoint-multica-daemon.sh

cat > /usr/local/bin/cube-start.sh <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

export PATH="/home/user/.npm-global/bin:/home/user/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
export HOME="${HOME:-/home/user}"
export DISPLAY="${DISPLAY:-:0}"
export SCREEN_GEOM="${SCREEN_GEOM:-1920x1080x24}"
export RESOLUTION="${RESOLUTION:-1920x1080x24}"
export RESOLUTION_WIDTH="${RESOLUTION_WIDTH:-1920}"
export RESOLUTION_HEIGHT="${RESOLUTION_HEIGHT:-1080}"
export VNC_PORT="${VNC_PORT:-5901}"
export NOVNC_PORT="${NOVNC_PORT:-6080}"

# Start VNC/noVNC best-effort, then hand off to the base image Code API stack.
/etc/cont-init.d/99-browser-vnc || true
exec /root/.jupyter/start-up.sh
EOF
chmod +x /usr/local/bin/cube-start.sh
'

docker commit \
  --change 'USER root' \
  --change 'ENV PATH=/home/user/.npm-global/bin:/home/user/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin' \
  --change 'ENTRYPOINT ["/usr/local/bin/cube-start.sh"]' \
  --change 'WORKDIR /workspace' \
  "${PATCH_CONTAINER}" "${CUBE_READY_IMAGE}" >/dev/null

cleanup
trap - EXIT

docker inspect "${CUBE_READY_IMAGE}" --format '[create-cube-template] ready image={{.Id}} entrypoint={{json .Config.Entrypoint}} workdir={{.Config.WorkingDir}}'

allow_args=()
if [[ -n "${ALLOW_OUT_CIDRS}" ]]; then
  normalized_cidrs="${ALLOW_OUT_CIDRS//,/ }"
  for cidr in ${normalized_cidrs}; do
    [[ -n "${cidr}" ]] && allow_args+=(--allow-out-cidr "${cidr}")
  done
fi

create_args=(
  template create-from-image
  --image "${CUBE_READY_IMAGE}"
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
CUBE_READY_IMAGE=${CUBE_READY_IMAGE}
SOURCE_IMAGE=${SOURCE_IMAGE}
EOF

log "wrote ${OUTPUT_ENV_FILE}"
echo "CUBE_TEMPLATE_ID=${CUBE_TEMPLATE_ID}"
echo "CUBE_TEMPLATE_JOB_ID=${CUBE_TEMPLATE_JOB_ID}"
