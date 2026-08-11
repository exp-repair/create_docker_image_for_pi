#!/usr/bin/env bash
# Configure and run the Multica daemon.
#
# By default this script supervises the daemon: if `multica daemon start
# --foreground` exits for any reason, it is restarted after a short delay.
# Set MULTICA_DAEMON_SUPERVISE=0 for a one-shot foreground run (debug).
set -euo pipefail

log() { echo "[entrypoint-multica-daemon] $*"; }

export HOME="${HOME:-/root}"
export PATH="/root/.local/bin:/root/.npm-global/bin:/root/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
MULTICA_BIN="${MULTICA_BIN:-/usr/local/bin/multica}"
MULTICA_PROFILE="${MULTICA_PROFILE:-}"
MULTICA_DAEMON_ENABLED="${MULTICA_DAEMON_ENABLED:-1}"
# Keep enabled by default so sandbox containers recover when the daemon dies.
MULTICA_DAEMON_SUPERVISE="${MULTICA_DAEMON_SUPERVISE:-1}"
MULTICA_DAEMON_RESTART_DELAY_SEC="${MULTICA_DAEMON_RESTART_DELAY_SEC:-2}"
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

run_daemon_once() {
  log "starting: ${MULTICA_BIN} ${args[*]}"
  "${MULTICA_BIN}" "${args[@]}"
}

if [[ "${MULTICA_DAEMON_SUPERVISE}" != "1" ]]; then
  exec "${MULTICA_BIN}" "${args[@]}"
fi

delay="${MULTICA_DAEMON_RESTART_DELAY_SEC}"
if ! [[ "${delay}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  delay=2
fi

log "supervisor enabled (restart_delay=${delay}s)"
while true; do
  set +e
  run_daemon_once
  code=$?
  set -e
  log "daemon exited code=${code}; restarting in ${delay}s"
  sleep "${delay}"
done
