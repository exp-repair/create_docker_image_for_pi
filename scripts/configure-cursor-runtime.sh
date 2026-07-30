#!/usr/bin/env bash
# Configure Cursor Agent CLI auth/path for Multica daemon discovery.
# Secrets come from runtime environment (CURSOR_API_KEY), not image layers.
set -euo pipefail

log() { echo "[configure-cursor-runtime] $*"; }

CURSOR_HOME="${CURSOR_HOME:-/root}"
CURSOR_ENV_FILE="${CURSOR_ENV_FILE:-${CURSOR_HOME}/.cursor/runtime.env}"
CURSOR_BIN="${CURSOR_BIN:-}"

resolve_cursor_bin() {
  if [[ -n "${CURSOR_BIN}" && -x "${CURSOR_BIN}" ]]; then
    return 0
  fi
  if [[ -n "${MULTICA_CURSOR_PATH:-}" && -x "${MULTICA_CURSOR_PATH}" ]]; then
    CURSOR_BIN="${MULTICA_CURSOR_PATH}"
    return 0
  fi
  if command -v cursor-agent >/dev/null 2>&1; then
    CURSOR_BIN="$(command -v cursor-agent)"
    return 0
  fi
  for candidate in \
    /usr/local/bin/cursor-agent \
    "${CURSOR_HOME}/.local/bin/cursor-agent" \
    "${CURSOR_HOME}/.local/bin/agent"
  do
    if [[ -x "${candidate}" ]]; then
      CURSOR_BIN="${candidate}"
      return 0
    fi
  done
  CURSOR_BIN=""
}

resolve_cursor_bin

if [[ -z "${CURSOR_BIN}" ]]; then
  log "WARN: cursor-agent not found; Multica will not register a Cursor runtime"
  exit 0
fi

export MULTICA_CURSOR_PATH="${MULTICA_CURSOR_PATH:-${CURSOR_BIN}}"
mkdir -p "$(dirname "${CURSOR_ENV_FILE}")"

{
  printf 'export PATH="/root/.local/bin:/root/.npm-global/bin:/root/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"\n'
  printf 'export MULTICA_CURSOR_PATH=%q\n' "${MULTICA_CURSOR_PATH}"
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then
    printf 'export CURSOR_API_KEY=%q\n' "${CURSOR_API_KEY}"
  fi
  if [[ -n "${MULTICA_CURSOR_MODEL:-}" ]]; then
    printf 'export MULTICA_CURSOR_MODEL=%q\n' "${MULTICA_CURSOR_MODEL}"
  fi
  # Cursor auth has known issues when forced through some HTTP proxies.
  # Keep Cursor API hosts out of proxy by default when a proxy is configured.
  if [[ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}${http_proxy:-}${https_proxy:-}" ]]; then
    local_no_proxy="${NO_PROXY:-${no_proxy:-}}"
    for host in api2.cursor.sh api3.cursor.sh api.cursor.sh cursor.sh .cursor.sh; do
      case ",${local_no_proxy}," in
        *",${host},"*) ;;
        *)
          if [[ -n "${local_no_proxy}" ]]; then
            local_no_proxy="${local_no_proxy},${host}"
          else
            local_no_proxy="${host}"
          fi
          ;;
      esac
    done
    printf 'export NO_PROXY=%q\n' "${local_no_proxy}"
    printf 'export no_proxy=%q\n' "${local_no_proxy}"
  fi
} > "${CURSOR_ENV_FILE}"
chmod 600 "${CURSOR_ENV_FILE}"

# shellcheck disable=SC1090
source "${CURSOR_ENV_FILE}"

if [[ -z "${CURSOR_API_KEY:-}" ]]; then
  log "WARN: CURSOR_API_KEY is empty; cursor-agent auth may fail until it is injected"
else
  log "CURSOR_API_KEY is set"
fi

version="$("${CURSOR_BIN}" --version 2>/dev/null || true)"
log "cursor-agent=${CURSOR_BIN}${version:+ (${version})} MULTICA_CURSOR_PATH=${MULTICA_CURSOR_PATH} model=${MULTICA_CURSOR_MODEL:-<default>}"
