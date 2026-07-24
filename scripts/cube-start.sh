#!/usr/bin/env bash
# Cube sandbox entrypoint: start browser/VNC helpers, then lightweight Code API.
set -euo pipefail

export HOME="${HOME:-/root}"
export PATH="/root/.npm-global/bin:/root/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
export DISPLAY="${DISPLAY:-:0}"
export SCREEN_GEOM="${SCREEN_GEOM:-1920x1080x24}"
export RESOLUTION="${RESOLUTION:-1920x1080x24}"
export RESOLUTION_WIDTH="${RESOLUTION_WIDTH:-1920}"
export RESOLUTION_HEIGHT="${RESOLUTION_HEIGHT:-1080}"
export VNC_PORT="${VNC_PORT:-5901}"
export NOVNC_PORT="${NOVNC_PORT:-6080}"
export CHROME_REMOTE_DEBUGGING_PORT="${CHROME_REMOTE_DEBUGGING_PORT:-9223}"
export CODE_INTERPRETER_HOST="${CODE_INTERPRETER_HOST:-0.0.0.0}"
export CODE_INTERPRETER_PORT="${CODE_INTERPRETER_PORT:-49999}"
export CODE_INTERPRETER_WORKDIR="${CODE_INTERPRETER_WORKDIR:-/workspace}"

/etc/cont-init.d/99-browser-vnc || true

if [[ "${MULTICA_AUTOSTART:-0}" == "1" ]]; then
  /usr/local/bin/start-multica-runtime.sh || true
fi

exec /usr/local/bin/start-lightweight-code-interpreter.sh
