#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${TAG:-cube-leagent-template:local}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-cube-sandbox-image.tencentcloudcr.com/demo/e2b-code-interpreter:v1.1-data}"
PI_CONFIG="${PI_CONFIG:-config/pi.env}"
MULTICA_REPO="${MULTICA_REPO:-/home/jian40/multica}"
MULTICA_CONTEXT_DIR="multica/server/bin"
MULTICA_CONTEXT_BIN="${MULTICA_CONTEXT_DIR}/multica"

EXTRA=(
  --build-arg "SANDBOX_IMAGE=${SANDBOX_IMAGE}"
)
[[ -n "${NOVNC_ARCHIVE_URL:-}" ]] && EXTRA+=(--build-arg "NOVNC_ARCHIVE_URL=${NOVNC_ARCHIVE_URL}")

if [[ ! -d "${MULTICA_REPO}/.git" ]]; then
  echo "[build.sh] ERROR: MULTICA_REPO is not a git checkout: ${MULTICA_REPO}" >&2
  exit 1
fi
MULTICA_BRANCH="$(git -C "${MULTICA_REPO}" rev-parse --abbrev-ref HEAD)"
if [[ "${MULTICA_BRANCH}" != "dev" ]]; then
  echo "[build.sh] WARN: ${MULTICA_REPO} is on branch ${MULTICA_BRANCH}, expected dev" >&2
fi
echo "[build.sh] building Multica CLI/daemon from ${MULTICA_REPO} (${MULTICA_BRANCH})"
make -C "${MULTICA_REPO}" build
if [[ ! -x "${MULTICA_REPO}/server/bin/multica" ]]; then
  echo "[build.sh] ERROR: make build did not produce ${MULTICA_REPO}/server/bin/multica" >&2
  exit 1
fi
mkdir -p "${MULTICA_CONTEXT_DIR}"
cp "${MULTICA_REPO}/server/bin/multica" "${MULTICA_CONTEXT_BIN}"
chmod +x "${MULTICA_CONTEXT_BIN}"

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
