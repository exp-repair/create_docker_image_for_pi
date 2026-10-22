#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${TAG:-coforge-pi:local}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-cube-sandbox-cn.tencentcloudcr.com/cube-sandbox/sandbox-code@sha256:b551b169de85c0216cce9453a8e22059ca47fd3dceced75e918cf1c8de60464b}"
PI_CONFIG="${PI_CONFIG:-config/pi.env}"

EXTRA=(
  --build-arg "SANDBOX_IMAGE=${SANDBOX_IMAGE}"
  --build-arg "NODE_MAJOR=${NODE_MAJOR:-22}"
  --build-arg "APT_MIRROR=${APT_MIRROR:-https://mirrors.aliyun.com/debian}"
  --build-arg "APT_SECURITY_MIRROR=${APT_SECURITY_MIRROR:-https://mirrors.aliyun.com/debian-security}"
)
mkdir -p coforge
if [[ -n "${COFORGE_RELEASE_FEED_URL:-}" ]]; then
  feed="${COFORGE_RELEASE_FEED_URL%/}"
  version="$(curl -fsSL "${feed}/latest" | tr -d '[:space:]')"
  case "${version}" in
    ""|latest|.|*..*|-*)
      echo "[build.sh] ERROR: feed latest is not a version: ${version}" >&2
      exit 1
      ;;
  esac
  if ! printf '%s' "${version}" | grep -Eq '^[A-Za-z0-9.+-]{1,100}$'; then
    echo "[build.sh] ERROR: feed latest is not a version: ${version}" >&2
    exit 1
  fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  echo "[build.sh] downloading ${feed}/${version}/linux-x64/coforge-computer.gz"
  curl -fsSL "${feed}/${version}/linux-x64/coforge-computer.gz" -o "${tmp}/coforge-computer.gz"
  curl -fsSL "${feed}/${version}/linux-x64/coforge-computer.sha256" -o "${tmp}/coforge-computer.sha256"
  gzip -dc "${tmp}/coforge-computer.gz" > coforge/coforge-computer
  expected="$(tr -d '[:space:]' < "${tmp}/coforge-computer.sha256")"
  actual="$(sha256sum coforge/coforge-computer | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "[build.sh] ERROR: Computer checksum mismatch" >&2
    exit 1
  fi
  if ! grep -a -q 'https://staging.coforge.cn' coforge/coforge-computer; then
    echo "[build.sh] ERROR: downloaded Computer is not baked for https://staging.coforge.cn" >&2
    exit 1
  fi
  if ! grep -a -q 'COFORGE_CLUSTER_TOKEN' coforge/coforge-computer; then
    echo "[build.sh] ERROR: downloaded Computer has no cloud host; publish the post-merge build first" >&2
    exit 1
  fi
  chmod 755 coforge/coforge-computer
  EXTRA+=(--build-arg "COMPUTER_VERSION=${version}")
  echo "[build.sh] staged CoForge Computer ${version} from ${feed}"
else
  COFORGE_COMPUTER_BIN="${COFORGE_COMPUTER_BIN:-${HOME}/.coforge/computer/install/active/coforge-computer}"
  if [[ ! -x "${COFORGE_COMPUTER_BIN}" ]]; then
    echo "[build.sh] ERROR: missing CoForge Computer binary: ${COFORGE_COMPUTER_BIN}" >&2
    exit 1
  fi
  cp "${COFORGE_COMPUTER_BIN}" coforge/coforge-computer
  chmod 755 coforge/coforge-computer
  echo "[build.sh] staged CoForge Computer from ${COFORGE_COMPUTER_BIN}"
fi

if [[ -f "${PI_CONFIG}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${PI_CONFIG}"
  set +a
  echo "[build.sh] loaded Pi build config from ${PI_CONFIG}"
fi

INSTALL_PI="${INSTALL_PI:-1}"
EXTRA+=(--build-arg "INSTALL_PI=${INSTALL_PI}")

if [[ "${INSTALL_PI}" == "1" ]]; then
  if [[ -z "${LENOVO_DEEPSEEK_V4_FLASH_API_KEY:-}" ]]; then
    echo "[build.sh] ERROR: LENOVO_DEEPSEEK_V4_FLASH_API_KEY is required in ${PI_CONFIG} (baked into image)" >&2
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
  echo "[build.sh] Pi install: enabled (suite ${PI_SUITE_VERSION:-0.1.17}); DeepSeek will be baked into the image"
else
  echo "[build.sh] Pi install: skipped (INSTALL_PI=0)"
fi

echo "[build.sh] SANDBOX_IMAGE=${SANDBOX_IMAGE}"
echo "[build.sh] APT_MIRROR=${APT_MIRROR:-https://mirrors.aliyun.com/debian}"
echo "[build.sh] tag=${TAG}"
# The host proxy listens on 127.0.0.1, which is the build container itself.
# Keep it for the release download above, and let apt use the mirror directly.
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
    -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
    docker build "${EXTRA[@]}" -t "${TAG}" .
