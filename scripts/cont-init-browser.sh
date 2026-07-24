#!/usr/bin/env bash
# Start VNC/noVNC and Pi web helpers beside the lightweight Cube Code API.
set -euo pipefail

log() { echo "[cont-init-browser] $*"; }

if pgrep -f "entrypoint-vnc.sh" >/dev/null 2>&1; then
  log "VNC stack already running"
  exit 0
fi

export HOME=/root
export DISPLAY="${DISPLAY:-:0}"

log "starting VNC stack"
/entrypoint-vnc.sh &

if ! pgrep -f "pi-web/server.js" >/dev/null 2>&1 && [[ -x /entrypoint-pi-web.sh ]]; then
  log "starting Pi web console"
  /entrypoint-pi-web.sh &
fi

sleep 1
log "done"
