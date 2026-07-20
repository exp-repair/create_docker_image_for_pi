#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${TAG:-cube-leagent-template:local}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-cube-sandbox-image.tencentcloudcr.com/demo/e2b-code-interpreter:v1.1-data}"
PI_CONFIG="${PI_CONFIG:-config/pi.env}"
MULTICA_CONTEXT_DIR="multica/bin"
MULTICA_CONTEXT_BIN="${MULTICA_CONTEXT_DIR}/multica"
MULTICA_RELEASE_REPO_WEB_URL="${MULTICA_RELEASE_REPO_WEB_URL:-https://github.com/LRM-Teams/multica}"

# Download Multica CLI/daemon on the host into the build context, then COPY into
# the image. This avoids GitHub downloads from inside docker build.
# Skip re-download if the file already exists:
#   MULTICA_SKIP_DOWNLOAD=1 ./scripts/build.sh
# Or point at an existing binary:
#   MULTICA_LOCAL_BIN=/usr/local/bin/multica ./scripts/build.sh

download_multica_release() {
  local dest="$1"
  local os arch latest version url tmp_dir

  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *)
      echo "[build.sh] ERROR: unsupported OS for Multica download: $(uname -s)" >&2
      return 1
      ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "[build.sh] ERROR: unsupported arch for Multica download: $(uname -m)" >&2
      return 1
      ;;
  esac

  echo "[build.sh] resolving latest Multica release from ${MULTICA_RELEASE_REPO_WEB_URL}"
  # Capture headers first. Piping curl|awk under `set -o pipefail` can exit 141
  # (SIGPIPE) when awk closes early, which looks like a silent stop.
  headers="$(
    curl -sS --http1.1 -I \
      --connect-timeout 30 --max-time 120 \
      --retry 5 --retry-delay 3 --retry-all-errors \
      "${MULTICA_RELEASE_REPO_WEB_URL}/releases/latest"
  )"
  latest="$(
    printf '%s\n' "${headers}" \
      | tr -d '\r' \
      | awk 'tolower($1)=="location:" {print $2; exit}' \
      | sed 's|.*/tag/||'
  )"
  if [[ -z "${latest}" ]]; then
    echo "[build.sh] ERROR: could not determine latest Multica release" >&2
    echo "[build.sh] response headers:" >&2
    printf '%s\n' "${headers}" >&2
    return 1
  fi
  version="${latest#v}"
  url="${MULTICA_RELEASE_REPO_WEB_URL}/releases/download/${latest}/multica-cli-${version}-${os}-${arch}.tar.gz"
  echo "[build.sh] downloading ${url}"

  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_dir}'" RETURN
  # -# shows a progress bar; avoid -s so download progress is visible.
  curl -fL --http1.1 --progress-bar \
    --connect-timeout 30 --max-time 600 \
    --retry 5 --retry-delay 3 --retry-all-errors \
    -o "${tmp_dir}/multica.tar.gz" \
    "${url}"
  tar -xzf "${tmp_dir}/multica.tar.gz" -C "${tmp_dir}" multica
  mkdir -p "$(dirname "${dest}")"
  cp "${tmp_dir}/multica" "${dest}"
  chmod +x "${dest}"
  echo "[build.sh] Multica binary ready: ${dest} (${latest})"
  "${dest}" version || true
}

EXTRA=(
  --build-arg "SANDBOX_IMAGE=${SANDBOX_IMAGE}"
)
[[ -n "${NOVNC_ARCHIVE_URL:-}" ]] && EXTRA+=(--build-arg "NOVNC_ARCHIVE_URL=${NOVNC_ARCHIVE_URL}")

if [[ -n "${MULTICA_LOCAL_BIN:-}" ]]; then
  if [[ ! -x "${MULTICA_LOCAL_BIN}" ]]; then
    echo "[build.sh] ERROR: MULTICA_LOCAL_BIN is not executable: ${MULTICA_LOCAL_BIN}" >&2
    exit 1
  fi
  mkdir -p "${MULTICA_CONTEXT_DIR}"
  cp "${MULTICA_LOCAL_BIN}" "${MULTICA_CONTEXT_BIN}"
  chmod +x "${MULTICA_CONTEXT_BIN}"
  echo "[build.sh] using local Multica binary from ${MULTICA_LOCAL_BIN}"
elif [[ "${MULTICA_SKIP_DOWNLOAD:-0}" == "1" && -x "${MULTICA_CONTEXT_BIN}" ]]; then
  echo "[build.sh] reusing existing Multica binary at ${MULTICA_CONTEXT_BIN}"
else
  download_multica_release "${MULTICA_CONTEXT_BIN}"
fi

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
