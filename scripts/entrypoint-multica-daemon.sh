#!/usr/bin/env bash
# Configure and run the Multica daemon under Multica's own supervisor.
#
# Architecture (matches `multica daemon install-service` / `computer supervise`
# intent, without systemd --user which Cube/Docker sandboxes do not provide):
#   1. Seed $HOME/.local/bin/multica (Machine Upgrade always swaps this path).
#   2. This script's outer loop acts as the OS process manager: if
#      `supervise` itself exits, restart it onto the current install path.
#   3. `daemon/computer supervise` keeps the worker alive across crashes and,
#      after a Machine Upgrade stages a new CLI, handoffs onto the Active
#      version (exit 75) and force-restarts if the worker stays stuck.
#
# Set MULTICA_DAEMON_MODE=foreground to fall back to start --foreground
# (debug only; upgrades may not reconnect cleanly).
# Set MULTICA_DAEMON_SUPERVISE=0 for a one-shot run without the outer loop.
set -euo pipefail

log() { echo "[entrypoint-multica-daemon] $*"; }

export HOME="${HOME:-/root}"
export PATH="/root/.local/bin:/root/.npm-global/bin:/root/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
MULTICA_IMAGE_BIN="${MULTICA_IMAGE_BIN:-/usr/local/bin/multica}"
MULTICA_INSTALL_BIN="${HOME}/.local/bin/multica"
MULTICA_PROFILE="${MULTICA_PROFILE:-}"
MULTICA_DAEMON_ENABLED="${MULTICA_DAEMON_ENABLED:-1}"
# Outer bash loop: keep `supervise` (or foreground) alive if it exits.
MULTICA_DAEMON_SUPERVISE="${MULTICA_DAEMON_SUPERVISE:-1}"
MULTICA_DAEMON_RESTART_DELAY_SEC="${MULTICA_DAEMON_RESTART_DELAY_SEC:-2}"
# Prefer Multica's built-in supervisor so Machine Upgrade handoffs auto-restart.
MULTICA_DAEMON_MODE="${MULTICA_DAEMON_MODE:-supervise}"
CURSOR_ENV_FILE="${CURSOR_ENV_FILE:-${HOME}/.cursor/runtime.env}"

if [[ "${MULTICA_DAEMON_ENABLED}" != "1" ]]; then
  log "disabled (MULTICA_DAEMON_ENABLED=${MULTICA_DAEMON_ENABLED})"
  exec sleep infinity
fi

seed_multica_install_path() {
  mkdir -p "$(dirname "${MULTICA_INSTALL_BIN}")"
  if [[ -x "${MULTICA_INSTALL_BIN}" ]]; then
    return 0
  fi
  local src=""
  if [[ -n "${MULTICA_BIN:-}" && -x "${MULTICA_BIN}" ]]; then
    src="${MULTICA_BIN}"
  elif [[ -x "${MULTICA_IMAGE_BIN}" ]]; then
    src="${MULTICA_IMAGE_BIN}"
  elif command -v multica >/dev/null 2>&1; then
    src="$(command -v multica)"
  fi
  if [[ -z "${src}" ]]; then
    log "ERROR: no Multica binary to seed ${MULTICA_INSTALL_BIN}" >&2
    return 1
  fi
  cp -a "${src}" "${MULTICA_INSTALL_BIN}"
  chmod +x "${MULTICA_INSTALL_BIN}"
  log "seeded Machine Upgrade install path ${MULTICA_INSTALL_BIN} from ${src}"
}

resolve_multica_bin() {
  if [[ -n "${MULTICA_BIN:-}" && -x "${MULTICA_BIN}" && "${MULTICA_BIN}" != "${MULTICA_IMAGE_BIN}" ]]; then
    printf '%s' "${MULTICA_BIN}"
    return 0
  fi
  if [[ -x "${MULTICA_INSTALL_BIN}" ]]; then
    printf '%s' "${MULTICA_INSTALL_BIN}"
    return 0
  fi
  if [[ -x "${MULTICA_IMAGE_BIN}" ]]; then
    printf '%s' "${MULTICA_IMAGE_BIN}"
    return 0
  fi
  command -v multica
}

multica_supports() {
  local bin="$1"
  shift
  [[ -x "${bin}" ]] || return 1
  "${bin}" "$@" -h >/dev/null 2>&1
}

resolve_multica_args() {
  local bin="$1"
  local mode="$2"
  local -a args=()

  if [[ "${mode}" == "supervise" ]]; then
    if multica_supports "${bin}" computer supervise; then
      args=(computer supervise)
    elif multica_supports "${bin}" daemon supervise; then
      args=(daemon supervise)
    else
      log "WARN: neither computer supervise nor daemon supervise is available; using computer start --foreground"
      args=(computer start --foreground)
    fi
  else
    if multica_supports "${bin}" computer start; then
      args=(computer start --foreground)
    elif multica_supports "${bin}" daemon start; then
      args=(daemon start --foreground)
    else
      args=(computer start --foreground)
    fi
  fi

  if [[ "${args[0]}" == "daemon" && -n "${MULTICA_PROFILE}" ]]; then
    args=(--profile "${MULTICA_PROFILE}" "${args[@]}")
  fi
  printf '%s\n' "${args[@]}"
}

if ! seed_multica_install_path; then
  log "ERROR: ${MULTICA_IMAGE_BIN} is not executable" >&2
  exit 1
fi

export MULTICA_COMPUTER_LAUNCH_BIN="${MULTICA_INSTALL_BIN}"

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

run_daemon_once() {
  local bin
  local -a args=()
  bin="$(resolve_multica_bin)"
  if [[ -z "${bin}" || ! -x "${bin}" ]]; then
    log "ERROR: Multica binary is not executable" >&2
    return 1
  fi
  mapfile -t args < <(resolve_multica_args "${bin}" "${MULTICA_DAEMON_MODE}")
  export MULTICA_COMPUTER_LAUNCH_BIN="${bin}"
  log "starting: ${bin} ${args[*]} (mode=${MULTICA_DAEMON_MODE})"
  "${bin}" "${args[@]}"
}

if [[ "${MULTICA_DAEMON_SUPERVISE}" != "1" ]]; then
  run_daemon_once
  exit $?
fi

delay="${MULTICA_DAEMON_RESTART_DELAY_SEC}"
if ! [[ "${delay}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  delay=2
fi

log "outer process manager enabled (restart_delay=${delay}s, mode=${MULTICA_DAEMON_MODE}, install=${MULTICA_INSTALL_BIN})"
while true; do
  set +e
  run_daemon_once
  code=$?
  set -e
  log "multica ${MULTICA_DAEMON_MODE} exited code=${code}; restarting onto $(resolve_multica_bin) in ${delay}s"
  sleep "${delay}"
done
