#!/usr/bin/env bash
# Fallback when sandbox-code does not start the VNC stack via s6 automatically.
set -euo pipefail

log() { echo "[cont-init-browser] $*"; }

if pgrep -f "entrypoint-vnc.sh" >/dev/null 2>&1; then
  log "VNC stack already running"
  exit 0
fi

export HOME=/home/user
export DISPLAY="${DISPLAY:-:0}"

log "starting VNC stack"
su -s /bin/bash user -c "exec /entrypoint-vnc.sh" &

if ! pgrep -f "pi-web/server.js" >/dev/null 2>&1 && [[ -x /entrypoint-pi-web.sh ]]; then
  log "starting Pi web console"
  su -s /bin/bash user -c "exec /entrypoint-pi-web.sh" &
fi

sleep 1
log "done"
