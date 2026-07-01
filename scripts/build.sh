#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${TAG:-cube-leagent-template:local}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-cube-sandbox-image.tencentcloudcr.com/demo/e2b-code-interpreter:v1.1-data}"
PI_CONFIG="${PI_CONFIG:-config/pi.env}"

EXTRA=(
  --build-arg "SANDBOX_IMAGE=${SANDBOX_IMAGE}"
)
[[ -n "${NOVNC_ARCHIVE_URL:-}" ]] && EXTRA+=(--build-arg "NOVNC_ARCHIVE_URL=${NOVNC_ARCHIVE_URL}")

if [[ -f "${PI_CONFIG}" ]]; then
  # Only non-secret build settings are used here. TEAM_* values are runtime envs.
  # shellcheck disable=SC1090
  set -a
  source "${PI_CONFIG}"
  set +a
  echo "[build.sh] loaded Pi build config from ${PI_CONFIG}"
fi

INSTALL_PI="${INSTALL_PI:-1}"
EXTRA+=(--build-arg "INSTALL_PI=${INSTALL_PI}")

if [[ "${INSTALL_PI}" == "1" ]]; then
  EXTRA+=(
    --build-arg "PI_SUITE_VERSION=${PI_SUITE_VERSION:-0.1.17}"
    --build-arg "PI_SUITE=${PI_SUITE:-npm:@lebronj/pi-suite}"
    --build-arg "PI_WORKSPACE_DIR=${PI_WORKSPACE_DIR:-/workspace}"
    --build-arg "PI_EVOLUTION_ENABLED=${PI_EVOLUTION_ENABLED:-1}"
  )
  [[ -n "${NPM_REGISTRY:-}" ]] && EXTRA+=(--build-arg "NPM_REGISTRY=${NPM_REGISTRY}")
  echo "[build.sh] Pi install: enabled (suite ${PI_SUITE_VERSION:-0.1.17}); TEAM_* will be injected at runtime"
else
  echo "[build.sh] Pi install: skipped (INSTALL_PI=0)"
fi

echo "[build.sh] SANDBOX_IMAGE=${SANDBOX_IMAGE}"
echo "[build.sh] tag=${TAG}"
docker build "${EXTRA[@]}" -t "${TAG}" .
