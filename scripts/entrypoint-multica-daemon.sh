#!/usr/bin/env bash
# Configure and start the Multica daemon in the foreground under s6.
set -euo pipefail

log() { echo "[entrypoint-multica-daemon] $*"; }

export HOME="${HOME:-/home/user}"
MULTICA_BIN="${MULTICA_BIN:-/usr/local/bin/multica}"
MULTICA_PROFILE="${MULTICA_PROFILE:-}"
MULTICA_DAEMON_ENABLED="${MULTICA_DAEMON_ENABLED:-1}"

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
