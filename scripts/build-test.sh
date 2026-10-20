#!/usr/bin/env bash
# Build the test/alpha Cube sandbox image.
# Independent of scripts/build.sh so the production image path is unchanged.
#
# Daemon feed matches:
#   curl -fsSL https://cdn.leagent.me/computer/install.sh | bash -s -- --version v0.4.24-alpha.79
# Default MULTICA_VERSION=test follows metainfo.json environments.test (latest alpha).
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${TAG:-cube-leagent-template-test:local}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-cube-sandbox-cn.tencentcloudcr.com/cube-sandbox/sandbox-code@sha256:b551b169de85c0216cce9453a8e22059ca47fd3dceced75e918cf1c8de60464b}"
PI_CONFIG="${PI_CONFIG:-config/pi.env}"
MULTICA_CONTEXT_DIR="multica/bin-test"
MULTICA_CONTEXT_BIN="${MULTICA_CONTEXT_DIR}/multica"
DOCKER_MULTICA_BIN="multica/bin/multica"
MULTICA_RELEASE_MANIFEST_BASE_URL="${MULTICA_RELEASE_MANIFEST_BASE_URL:-https://cdn.leagent.me/computer}"
MULTICA_INSTALL_SCRIPT_URL="${MULTICA_INSTALL_SCRIPT_URL:-${MULTICA_RELEASE_MANIFEST_BASE_URL}/install.sh}"
# test | vX.Y.Z-(alpha|beta|rc).N  (default: latest alpha from the test channel)
MULTICA_VERSION="${MULTICA_VERSION:-test}"

# Override:
#   MULTICA_VERSION=v0.4.24-alpha.79 ./scripts/build-test.sh
#   MULTICA_SKIP_DOWNLOAD=1 ./scripts/build-test.sh
#   MULTICA_LOCAL_BIN=$HOME/.local/bin/multica ./scripts/build-test.sh

STAGE_BACKUP=""
STAGED_DOCKER_BIN=0

restore_production_multica_bin() {
  if [[ "${STAGED_DOCKER_BIN}" != "1" ]]; then
    return 0
  fi
  if [[ -n "${STAGE_BACKUP}" && -f "${STAGE_BACKUP}" ]]; then
    mkdir -p "$(dirname "${DOCKER_MULTICA_BIN}")"
    mv -f "${STAGE_BACKUP}" "${DOCKER_MULTICA_BIN}"
    echo "[build-test.sh] restored production Multica binary at ${DOCKER_MULTICA_BIN}"
  else
    rm -f "${DOCKER_MULTICA_BIN}"
  fi
  STAGE_BACKUP=""
  STAGED_DOCKER_BIN=0
}

download_multica_release() {
  local dest="$1"
  local os arch platform meta_file manifest_file selector env_name latest url sha256 tmp_dir actual expected

  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *)
      echo "[build-test.sh] ERROR: unsupported OS for Multica download: $(uname -s)" >&2
      return 1
      ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "[build-test.sh] ERROR: unsupported arch for Multica download: $(uname -m)" >&2
      return 1
      ;;
  esac
  platform="${os}-${arch}"
  selector="${MULTICA_VERSION}"

  meta_file="$(mktemp)"
  manifest_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${meta_file}' '${manifest_file}'" RETURN

  case "${selector}" in
    latest|test)
      if [[ "${selector}" == "latest" ]]; then
        echo "[build-test.sh] WARN: MULTICA_VERSION=latest bakes the production daemon into the test image" >&2
        env_name="production"
      else
        env_name="test"
      fi
      echo "[build-test.sh] fetching Multica metainfo from ${MULTICA_RELEASE_MANIFEST_BASE_URL}/metainfo.json (${env_name})"
      if ! curl -fsSL --http1.1 \
        --connect-timeout 30 --max-time 120 \
        --retry 5 --retry-delay 3 --retry-all-errors \
        -o "${meta_file}" \
        "${MULTICA_RELEASE_MANIFEST_BASE_URL}/metainfo.json"
      then
        echo "[build-test.sh] ERROR: could not fetch ${MULTICA_RELEASE_MANIFEST_BASE_URL}/metainfo.json" >&2
        echo "[build-test.sh] hint: host may need proxy access to cdn.leagent.me, or reuse a local binary" >&2
        return 1
      fi
      if ! python3 - "${meta_file}" "${manifest_file}" "${env_name}" <<'PY'
import json, sys
src, dst, env = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(src))
if data.get("schema_version") != 1:
    raise SystemExit(f"unsupported metainfo schema_version={data.get('schema_version')!r}")
env_data = (data.get("environments") or {}).get(env)
if not isinstance(env_data, dict):
    raise SystemExit(f"missing release environment {env!r}")
json.dump(env_data, open(dst, "w"))
PY
      then
        echo "[build-test.sh] ERROR: could not resolve environment '${env_name}' from metainfo.json" >&2
        return 1
      fi
      ;;
    v[0-9]*)
      echo "[build-test.sh] fetching Multica pinned manifest from ${MULTICA_RELEASE_MANIFEST_BASE_URL}/${selector#v}/manifest.json"
      if ! curl -fsSL --http1.1 \
        --connect-timeout 30 --max-time 120 \
        --retry 5 --retry-delay 3 --retry-all-errors \
        -o "${manifest_file}" \
        "${MULTICA_RELEASE_MANIFEST_BASE_URL}/${selector#v}/manifest.json"
      then
        echo "[build-test.sh] ERROR: could not fetch pinned manifest for ${selector}" >&2
        return 1
      fi
      ;;
    *)
      echo "[build-test.sh] ERROR: invalid MULTICA_VERSION='${selector}'; use test or vX.Y.Z[-(alpha|beta|rc).N]" >&2
      return 1
      ;;
  esac

  latest="$(python3 - <<PY
import json
print(json.load(open("${manifest_file}")).get("tag") or "")
PY
)"
  url="$(python3 - <<PY
import json
data = json.load(open("${manifest_file}"))
print((data.get("platforms") or {}).get("${platform}", {}).get("url") or "")
PY
)"
  sha256="$(python3 - <<PY
import json
data = json.load(open("${manifest_file}"))
print((data.get("platforms") or {}).get("${platform}", {}).get("sha256") or "")
PY
)"

  if [[ -z "${latest}" || -z "${url}" || -z "${sha256}" ]]; then
    echo "[build-test.sh] ERROR: manifest missing tag/url/sha256 for platform ${platform}" >&2
    return 1
  fi

  case "${latest}" in
    *-alpha.*|*-beta.*|*-rc.*) ;;
    *)
      echo "[build-test.sh] ERROR: test image requires an alpha/beta/rc daemon, got ${latest}" >&2
      echo "[build-test.sh] hint: keep MULTICA_VERSION=test, or pin e.g. MULTICA_VERSION=v0.4.24-alpha.79" >&2
      return 1
      ;;
  esac

  echo "[build-test.sh] downloading ${url} (${latest})"
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_dir}'; rm -f '${meta_file}' '${manifest_file}'" RETURN
  if ! curl -fL --http1.1 --progress-bar \
    --connect-timeout 30 --max-time 600 \
    --retry 5 --retry-delay 3 --retry-all-errors \
    -o "${tmp_dir}/multica.tar.gz" \
    "${url}"
  then
    echo "[build-test.sh] ERROR: failed to download ${url}" >&2
    return 1
  fi

  actual="$(sha256sum "${tmp_dir}/multica.tar.gz" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
  expected="$(printf '%s' "${sha256}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "[build-test.sh] ERROR: checksum mismatch for Multica archive" >&2
    echo "[build-test.sh] expected=${expected}" >&2
    echo "[build-test.sh] actual=${actual}" >&2
    return 1
  fi

  tar -xzf "${tmp_dir}/multica.tar.gz" -C "${tmp_dir}" multica
  mkdir -p "$(dirname "${dest}")"
  cp "${tmp_dir}/multica" "${dest}"
  chmod +x "${dest}"
  echo "[build-test.sh] Multica binary ready: ${dest} (${latest})"
  "${dest}" version || true
}

stage_test_multica_for_docker() {
  if [[ ! -x "${MULTICA_CONTEXT_BIN}" ]]; then
    echo "[build-test.sh] ERROR: missing test Multica binary: ${MULTICA_CONTEXT_BIN}" >&2
    exit 1
  fi
  mkdir -p "$(dirname "${DOCKER_MULTICA_BIN}")"
  if [[ -e "${DOCKER_MULTICA_BIN}" ]]; then
    STAGE_BACKUP="$(mktemp)"
    cp -a "${DOCKER_MULTICA_BIN}" "${STAGE_BACKUP}"
  fi
  cp -a "${MULTICA_CONTEXT_BIN}" "${DOCKER_MULTICA_BIN}"
  chmod +x "${DOCKER_MULTICA_BIN}"
  STAGED_DOCKER_BIN=1
  echo "[build-test.sh] staged test Multica binary for Docker COPY (${DOCKER_MULTICA_BIN})"
}

trap restore_production_multica_bin EXIT

EXTRA=(
  --build-arg "SANDBOX_IMAGE=${SANDBOX_IMAGE}"
  --build-arg "NODE_MAJOR=${NODE_MAJOR:-22}"
  --build-arg "APT_MIRROR=${APT_MIRROR:-https://mirrors.aliyun.com/debian}"
  --build-arg "APT_SECURITY_MIRROR=${APT_SECURITY_MIRROR:-https://mirrors.aliyun.com/debian-security}"
  --build-arg "PIP_INDEX_URL=${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
  --build-arg "PIP_TRUSTED_HOST=${PIP_TRUSTED_HOST:-mirrors.aliyun.com}"
)
for proxy_key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
  if [[ -n "${!proxy_key:-}" ]]; then
    EXTRA+=(--build-arg "${proxy_key}=${!proxy_key}")
  fi
done
[[ -n "${NOVNC_ARCHIVE_URL:-}" ]] && EXTRA+=(--build-arg "NOVNC_ARCHIVE_URL=${NOVNC_ARCHIVE_URL}")

echo "[build-test.sh] test/alpha Multica channel: MULTICA_VERSION=${MULTICA_VERSION}"
echo "[build-test.sh] image tag: ${TAG}"

if [[ -n "${MULTICA_LOCAL_BIN:-}" ]]; then
  if [[ ! -x "${MULTICA_LOCAL_BIN}" ]]; then
    echo "[build-test.sh] ERROR: MULTICA_LOCAL_BIN is not executable: ${MULTICA_LOCAL_BIN}" >&2
    exit 1
  fi
  mkdir -p "${MULTICA_CONTEXT_DIR}"
  cp "${MULTICA_LOCAL_BIN}" "${MULTICA_CONTEXT_BIN}"
  chmod +x "${MULTICA_CONTEXT_BIN}"
  echo "[build-test.sh] using local Multica binary from ${MULTICA_LOCAL_BIN}"
elif [[ "${MULTICA_SKIP_DOWNLOAD:-0}" == "1" ]]; then
  if [[ ! -x "${MULTICA_CONTEXT_BIN}" ]]; then
    echo "[build-test.sh] ERROR: MULTICA_SKIP_DOWNLOAD=1 but missing executable: ${MULTICA_CONTEXT_BIN}" >&2
    exit 1
  fi
  echo "[build-test.sh] reusing existing Multica binary at ${MULTICA_CONTEXT_BIN}"
  "${MULTICA_CONTEXT_BIN}" version || true
else
  if ! download_multica_release "${MULTICA_CONTEXT_BIN}"; then
    if [[ -x "${MULTICA_CONTEXT_BIN}" ]]; then
      echo "[build-test.sh] WARN: Multica CDN download failed; falling back to existing ${MULTICA_CONTEXT_BIN}" >&2
      "${MULTICA_CONTEXT_BIN}" version || true
    else
      echo "[build-test.sh] ERROR: Multica download failed and no local binary at ${MULTICA_CONTEXT_BIN}" >&2
      echo "[build-test.sh] hint: curl -fsSL ${MULTICA_INSTALL_SCRIPT_URL} | bash -s -- --version ${MULTICA_VERSION}" >&2
      echo "[build-test.sh]       then MULTICA_LOCAL_BIN=\$HOME/.local/bin/multica ./scripts/build-test.sh" >&2
      exit 1
    fi
  fi
fi

stage_test_multica_for_docker

if [[ -f "${PI_CONFIG}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${PI_CONFIG}"
  set +a
  echo "[build-test.sh] loaded Pi build config from ${PI_CONFIG}"
fi

INSTALL_PI="${INSTALL_PI:-1}"
INSTALL_CURSOR="${INSTALL_CURSOR:-1}"
EXTRA+=(--build-arg "INSTALL_PI=${INSTALL_PI}")
EXTRA+=(--build-arg "INSTALL_CURSOR=${INSTALL_CURSOR}")

if [[ "${INSTALL_PI}" == "1" ]]; then
  if [[ -z "${LENOVO_DEEPSEEK_V4_FLASH_API_KEY:-}" ]]; then
    echo "[build-test.sh] ERROR: LENOVO_DEEPSEEK_V4_FLASH_API_KEY is required in ${PI_CONFIG} (baked into image)" >&2
    exit 1
  fi
  EXTRA+=(
    --build-arg "PI_SUITE_VERSION=${PI_SUITE_VERSION:-0.1.17}"
    --build-arg "PI_SUITE=${PI_SUITE:-npm:@lebronj/pi-suite}"
    --build-arg "PI_WORKSPACE_DIR=${PI_WORKSPACE_DIR:-/workspace}"
    --build-arg "PI_EVOLUTION_ENABLED=${PI_EVOLUTION_ENABLED:-1}"
    --build-arg "LENOVO_DEEPSEEK_V4_FLASH_API_KEY=${LENOVO_DEEPSEEK_V4_FLASH_API_KEY}"
    --build-arg "LENOVO_DEEPSEEK_PROVIDER=${LENOVO_DEEPSEEK_PROVIDER:-openai}"
    --build-arg "LENOVO_DEEPSEEK_MODEL=${LENOVO_DEEPSEEK_MODEL:-DeepSeek}"
    --build-arg "LENOVO_DEEPSEEK_BASE_URL=${LENOVO_DEEPSEEK_BASE_URL:-https://modelfactory.lenovo.com/llm/v1}"
    --build-arg "LENOVO_DEEPSEEK_MODEL_NAME=${LENOVO_DEEPSEEK_MODEL_NAME:-DeepSeek}"
  )
  [[ -n "${NPM_REGISTRY:-}" ]] && EXTRA+=(--build-arg "NPM_REGISTRY=${NPM_REGISTRY}")
  echo "[build-test.sh] Pi install: enabled (suite ${PI_SUITE_VERSION:-0.1.17}); DeepSeek will be baked into the image"
else
  echo "[build-test.sh] Pi install: skipped (INSTALL_PI=0)"
fi

if [[ "${INSTALL_CURSOR}" == "1" ]]; then
  echo "[build-test.sh] Cursor Agent install: enabled; CURSOR_API_KEY will be injected at runtime"
else
  echo "[build-test.sh] Cursor Agent install: skipped (INSTALL_CURSOR=0)"
fi

echo "[build-test.sh] SANDBOX_IMAGE=${SANDBOX_IMAGE}"
echo "[build-test.sh] APT_MIRROR=${APT_MIRROR:-https://mirrors.aliyun.com/debian}"
echo "[build-test.sh] PIP_INDEX_URL=${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
echo "[build-test.sh] tag=${TAG}"
docker build "${EXTRA[@]}" -t "${TAG}" .
echo "[build-test.sh] built ${TAG}"
