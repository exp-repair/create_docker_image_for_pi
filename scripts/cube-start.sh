#!/usr/bin/env bash
# Cube sandbox entrypoint: start VNC/noVNC, then the base Code API stack.
set -euo pipefail

export PATH="/home/user/.npm-global/bin:/home/user/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
export DISPLAY="${DISPLAY:-:0}"
export SCREEN_GEOM="${SCREEN_GEOM:-1920x1080x24}"
export RESOLUTION="${RESOLUTION:-1920x1080x24}"
export RESOLUTION_WIDTH="${RESOLUTION_WIDTH:-1920}"
export RESOLUTION_HEIGHT="${RESOLUTION_HEIGHT:-1080}"
export VNC_PORT="${VNC_PORT:-5901}"
export NOVNC_PORT="${NOVNC_PORT:-6080}"
export E2B_LOCAL="${E2B_LOCAL:-1}"

# VNC stack runs as user via cont-init; do not set HOME=/home/user here for root.
/etc/cont-init.d/99-browser-vnc || true

# Match e2b-code-interpreter base image entrypoint: sudo + E2B_LOCAL keeps
# Jupyter/Code API startup stable (direct root exec with HOME=user breaks Jupyter).
exec sudo --preserve-env=E2B_LOCAL,PATH,DISPLAY,SCREEN_GEOM,RESOLUTION,RESOLUTION_WIDTH,RESOLUTION_HEIGHT,VNC_PORT,NOVNC_PORT \
  /root/.jupyter/start-up.sh
