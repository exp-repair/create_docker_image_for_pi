#!/usr/bin/env bash
# Configure and run the Multica daemon under Multica's own supervisor.
#
# Architecture (matches `multica daemon install-service` intent, without
# systemd --user which Cube/Docker sandboxes do not provide):
#   1. This script's outer loop acts as the OS process manager: if
#      `multica daemon supervise` itself exits, restart it.
#   2. `daemon supervise` keeps the worker alive across crashes and, after a
#      Machine Upgrade stages a new CLI, handoffs onto the Active version
#      (exit 75) and force-restarts if the worker stays stuck on a stale build.
#
# Set MULTICA_DAEMON_MODE=foreground to fall back to `daemon start --foreground`
# (debug only; upgrades may not reconnect cleanly).
# Set MULTICA_DAEMON_SUPERVISE=0 for a one-shot run without the outer loop.
set -euo pipefail

log() { echo "[entrypoint-multica-daemon] $*"; }

export HOME="${HOME:-/root}"
export PATH="/root/.local/bin:/root/.npm-global/bin:/root/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
MULTICA_BIN="${MULTICA_BIN:-/usr/local/bin/multica}"
MULTICA_PROFILE="${MULTICA_PROFILE:-}"
MULTICA_DAEMON_ENABLED="${MULTICA_DAEMON_ENABLED:-1}"
# Outer bash loop: keep `daemon supervise` (or foreground) alive if it exits.
MULTICA_DAEMON_SUPERVISE="${MULTICA_DAEMON_SUPERVISE:-1}"
MULTICA_DAEMON_RESTART_DELAY_SEC="${MULTICA_DAEMON_RESTART_DELAY_SEC:-2}"
# Prefer Multica's built-in supervisor so Machine Upgrade handoffs auto-restart.
MULTICA_DAEMON_MODE="${MULTICA_DAEMON_MODE:-supervise}"
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

case "${MULTICA_DAEMON_MODE}" in
  supervise|foreground) ;;
  *)
    log "WARN: unknown MULTICA_DAEMON_MODE=${MULTICA_DAEMON_MODE}; using supervise"
    MULTICA_DAEMON_MODE=supervise
    ;;
esac

if [[ "${MULTICA_DAEMON_MODE}" == "supervise" ]]; then
  args=(daemon supervise)
else
  args=(daemon start --foreground)
fi

if [[ -n "${MULTICA_PROFILE}" ]]; then
  args=(--profile "${MULTICA_PROFILE}" "${args[@]}")
fi

run_daemon_once() {
  log "starting: ${MULTICA_BIN} ${args[*]} (mode=${MULTICA_DAEMON_MODE})"
  "${MULTICA_BIN}" "${args[@]}"
}

if [[ "${MULTICA_DAEMON_SUPERVISE}" != "1" ]]; then
  exec "${MULTICA_BIN}" "${args[@]}"
fi

delay="${MULTICA_DAEMON_RESTART_DELAY_SEC}"
if ! [[ "${delay}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  delay=2
fi

log "outer process manager enabled (restart_delay=${delay}s, mode=${MULTICA_DAEMON_MODE})"
while true; do
  set +e
  run_daemon_once
  code=$?
  set -e
  log "multica ${MULTICA_DAEMON_MODE} exited code=${code}; restarting in ${delay}s"
  sleep "${delay}"
done
