#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${TAG:-coforge-pi:local}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-cube-sandbox-cn.tencentcloudcr.com/cube-sandbox/sandbox-code@sha256:b551b169de85c0216cce9453a8e22059ca47fd3dceced75e918cf1c8de60464b}"
PI_CONFIG="${PI_CONFIG:-config/pi.env}"
MULTICA_CONTEXT_DIR="multica/bin"
MULTICA_CONTEXT_BIN="${MULTICA_CONTEXT_DIR}/multica"
# Official LeAgent/Multica CLI feed (GitHub LRM-Teams releases 404 without auth).
# Same feed as:
#   curl -fsSL https://cdn.leagent.me/computer/install.sh | bash -s -- --version test
# CDN now publishes metainfo.json (production/test). latest.json is gone (404).
MULTICA_RELEASE_MANIFEST_BASE_URL="${MULTICA_RELEASE_MANIFEST_BASE_URL:-https://cdn.leagent.me/computer}"
MULTICA_INSTALL_SCRIPT_URL="${MULTICA_INSTALL_SCRIPT_URL:-${MULTICA_RELEASE_MANIFEST_BASE_URL}/install.sh}"
# latest | test | vX.Y.Z[-(alpha|beta|rc).N]
MULTICA_VERSION="${MULTICA_VERSION:-latest}"

# Download Multica CLI/daemon on the host into the build context, then COPY into
# the image. Prefer the public CDN feed used by install.sh.
# Override:
#   MULTICA_VERSION=test ./scripts/build.sh
#   MULTICA_SKIP_DOWNLOAD=1 ./scripts/build.sh          # force reuse local
#   MULTICA_LOCAL_BIN=/usr/local/bin/multica ./scripts/build.sh

download_multica_release() {
  local dest="$1"
  local os arch platform meta_file manifest_file selector env_name latest url sha256 tmp_dir actual expected

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
  platform="${os}-${arch}"
  selector="${MULTICA_VERSION}"

  meta_file="$(mktemp)"
  manifest_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${meta_file}' '${manifest_file}'" RETURN

  case "${selector}" in
    latest|test)
      if [[ "${selector}" == "latest" ]]; then
        env_name="production"
      else
        env_name="test"
      fi
      echo "[build.sh] fetching Multica metainfo from ${MULTICA_RELEASE_MANIFEST_BASE_URL}/metainfo.json (${env_name})"
      if ! curl -fsSL --http1.1 \
        --connect-timeout 30 --max-time 120 \
        --retry 5 --retry-delay 3 --retry-all-errors \
        -o "${meta_file}" \
        "${MULTICA_RELEASE_MANIFEST_BASE_URL}/metainfo.json"
      then
        echo "[build.sh] ERROR: could not fetch ${MULTICA_RELEASE_MANIFEST_BASE_URL}/metainfo.json" >&2
        echo "[build.sh] hint: host may need proxy access to cdn.leagent.me, or reuse a local binary" >&2
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
        echo "[build.sh] ERROR: could not resolve environment '${env_name}' from metainfo.json" >&2
        return 1
      fi
      ;;
    v[0-9]*)
      echo "[build.sh] fetching Multica pinned manifest from ${MULTICA_RELEASE_MANIFEST_BASE_URL}/${selector#v}/manifest.json"
      if ! curl -fsSL --http1.1 \
        --connect-timeout 30 --max-time 120 \
        --retry 5 --retry-delay 3 --retry-all-errors \
        -o "${manifest_file}" \
        "${MULTICA_RELEASE_MANIFEST_BASE_URL}/${selector#v}/manifest.json"
      then
        echo "[build.sh] ERROR: could not fetch pinned manifest for ${selector}" >&2
        return 1
      fi
      ;;
    *)
      echo "[build.sh] ERROR: invalid MULTICA_VERSION='${selector}'; use latest, test, or vX.Y.Z[-(alpha|beta|rc).N]" >&2
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
    echo "[build.sh] ERROR: manifest missing tag/url/sha256 for platform ${platform}" >&2
    return 1
  fi

  echo "[build.sh] downloading ${url} (${latest})"
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_dir}'; rm -f '${meta_file}' '${manifest_file}'" RETURN
  if ! curl -fL --http1.1 --progress-bar \
    --connect-timeout 30 --max-time 600 \
    --retry 5 --retry-delay 3 --retry-all-errors \
    -o "${tmp_dir}/multica.tar.gz" \
    "${url}"
  then
    echo "[build.sh] ERROR: failed to download ${url}" >&2
    return 1
  fi

  actual="$(sha256sum "${tmp_dir}/multica.tar.gz" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
  expected="$(printf '%s' "${sha256}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "[build.sh] ERROR: checksum mismatch for Multica archive" >&2
    echo "[build.sh] expected=${expected}" >&2
    echo "[build.sh] actual=${actual}" >&2
    return 1
  fi

  tar -xzf "${tmp_dir}/multica.tar.gz" -C "${tmp_dir}" multica
  mkdir -p "$(dirname "${dest}")"
  cp "${tmp_dir}/multica" "${dest}"
  chmod +x "${dest}"
  echo "[build.sh] Multica binary ready: ${dest} (${latest})"
  "${dest}" version || true
}

EXTRA=(
  --build-arg "SANDBOX_IMAGE=${SANDBOX_IMAGE}"
  --build-arg "NODE_MAJOR=${NODE_MAJOR:-22}"
  --build-arg "APT_MIRROR=${APT_MIRROR:-https://mirrors.aliyun.com/debian}"
  --build-arg "APT_SECURITY_MIRROR=${APT_SECURITY_MIRROR:-https://mirrors.aliyun.com/debian-security}"
)
for proxy_key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
  if [[ -n "${!proxy_key:-}" ]]; then
    EXTRA+=(--build-arg "${proxy_key}=${!proxy_key}")
  fi
done
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
docker build "${EXTRA[@]}" -t "${TAG}" .
