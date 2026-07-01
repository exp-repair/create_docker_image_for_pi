#!/usr/bin/env bash
# Dynamically configure Pi + Multica and start the Multica daemon for this sandbox.
set -euo pipefail

log() { echo "[start-multica-runtime] $*"; }

MULTICA_USER="${MULTICA_USER:-user}"
MULTICA_HOME="${MULTICA_HOME:-/home/${MULTICA_USER}}"
export HOME="${HOME:-${MULTICA_HOME}}"

if [[ "$(id -u)" == "0" && -n "${RUN_AS_USER:-1}" ]] && id "${MULTICA_USER}" >/dev/null 2>&1; then
  exec runuser -u "${MULTICA_USER}" -- env \
    HOME="${MULTICA_HOME}" \
    PATH="/home/${MULTICA_USER}/.npm-global/bin:/home/${MULTICA_USER}/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin" \
    TEAM_API_KEY="${TEAM_API_KEY:-}" \
    TEAM_BASE_URL="${TEAM_BASE_URL:-}" \
    TEAM_MODEL="${TEAM_MODEL:-}" \
    MULTICA_SERVER_URL="${MULTICA_SERVER_URL:-}" \
    MULTICA_APP_URL="${MULTICA_APP_URL:-}" \
    MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID:-}" \
    MULTICA_TOKEN="${MULTICA_TOKEN:-}" \
    MULTICA_PROFILE="${MULTICA_PROFILE:-}" \
    MULTICA_DAEMON_ENABLED="${MULTICA_DAEMON_ENABLED:-1}" \
    RUN_AS_USER= \
    /usr/local/bin/start-multica-runtime.sh "$@"
fi

mkdir -p "${MULTICA_HOME}/.multica"

if [[ -n "${TEAM_API_KEY:-}" || -n "${TEAM_BASE_URL:-}" || -n "${TEAM_MODEL:-}" ]]; then
  configure-pi-runtime.sh
else
  log "TEAM_* not provided; leaving Pi config unchanged"
fi

configure-multica-runtime.sh

if command -v multica >/dev/null 2>&1; then
  multica daemon stop >/dev/null 2>&1 || true
fi
pkill -f "multica.*daemon start --foreground" >/dev/null 2>&1 || true

log "starting Multica daemon"
nohup /entrypoint-multica-daemon.sh >>"${MULTICA_HOME}/.multica/daemon.log" 2>&1 &

sleep 2
if pgrep -f "multica.*daemon start --foreground" >/dev/null 2>&1; then
  log "daemon process started"
else
  log "daemon process not running yet; check ${MULTICA_HOME}/.multica/daemon.log"
fi
