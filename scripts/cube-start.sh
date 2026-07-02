#!/usr/bin/env bash
# Cube sandbox entrypoint: start VNC/noVNC, then the base Code API stack.
set -euo pipefail

export PATH="/home/user/.npm-global/bin:/home/user/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
export HOME="${HOME:-/home/user}"
export DISPLAY="${DISPLAY:-:0}"
export SCREEN_GEOM="${SCREEN_GEOM:-1920x1080x24}"
export RESOLUTION="${RESOLUTION:-1920x1080x24}"
export RESOLUTION_WIDTH="${RESOLUTION_WIDTH:-1920}"
export RESOLUTION_HEIGHT="${RESOLUTION_HEIGHT:-1080}"
export VNC_PORT="${VNC_PORT:-5901}"
export NOVNC_PORT="${NOVNC_PORT:-6080}"

/etc/cont-init.d/99-browser-vnc || true
exec /root/.jupyter/start-up.sh
