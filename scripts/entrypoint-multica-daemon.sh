#!/usr/bin/env bash
# Configure and start the Multica daemon in the foreground.
set -euo pipefail

log() { echo "[entrypoint-multica-daemon] $*"; }

export HOME="${HOME:-/root}"
export PATH="/root/.local/bin:/root/.npm-global/bin:/root/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
MULTICA_BIN="${MULTICA_BIN:-/usr/local/bin/multica}"
MULTICA_PROFILE="${MULTICA_PROFILE:-}"
MULTICA_DAEMON_ENABLED="${MULTICA_DAEMON_ENABLED:-1}"
CURSOR_ENV_FILE="${CURSOR_ENV_FILE:-${HOME}/.cursor/runtime.env}"

if [[ "${MULTICA_DAEMON_ENABLED}" != "1" ]]; then
  log "disabled (MULTICA_DAEMON_ENABLED=${MULTICA_DAEMON_ENABLED})"
  exec sleep infinity
fi

if [[ ! -x "${MULTICA_BIN}" ]]; then
  log "ERROR: ${MULTICA_BIN} is not executable" >&2
  exit 1
fi

if command -v configure-pi-runtime.sh >/dev/null 2>&1; then
  configure-pi-runtime.sh
fi

if command -v configure-cursor-runtime.sh >/dev/null 2>&1; then
  configure-cursor-runtime.sh
fi
if [[ -f "${CURSOR_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CURSOR_ENV_FILE}"
fi

if ! configure-multica-runtime.sh; then
  log "configuration incomplete; daemon not started"
  exec sleep infinity
fi

args=(daemon start --foreground)
if [[ -n "${MULTICA_PROFILE}" ]]; then
  args=(--profile "${MULTICA_PROFILE}" "${args[@]}")
fi

log "starting: ${MULTICA_BIN} ${args[*]}"
exec "${MULTICA_BIN}" "${args[@]}"
