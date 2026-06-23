#!/usr/bin/env bash
# Xvfb (:0) + x11vnc (:5901) + noVNC (:6080). Chromium is started by Leagent via CDP 9223.
set -euo pipefail

export HOME=/home/user

SCREEN_GEOM="${SCREEN_GEOM:-${RESOLUTION:-1920x1080x24}}"
VNC_PORT="${VNC_PORT:-5901}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
export DISPLAY="${DISPLAY:-:0}"

echo "[entrypoint-vnc] DISPLAY=${DISPLAY} SCREEN=${SCREEN_GEOM} VNC=${VNC_PORT} noVNC=${NOVNC_PORT}"

Xvfb "${DISPLAY}" -screen 0 "${SCREEN_GEOM}" -ac +extension RANDR +render -noreset &
XVFB_PID=$!

cleanup() {
  echo "[entrypoint-vnc] shutting down..."
  kill "${WEBSOCKIFY_PID:-}" 2>/dev/null || true
  kill "${X11VNC_PID:-}" 2>/dev/null || true
  kill "${XVFB_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 50); do
  if xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if ! xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
  echo "[entrypoint-vnc] ERROR: Xvfb did not become ready on ${DISPLAY}" >&2
  exit 1
fi

X11VNC_COMMON=(
  x11vnc
  -display "${DISPLAY}"
  -forever
  -shared
  -rfbport "${VNC_PORT}"
  -listen 0.0.0.0
  -noxdamage
)

if [[ -n "${VNC_PASSWORD:-}" ]]; then
  mkdir -p "${HOME}/.vnc"
  x11vnc -storepasswd "${VNC_PASSWORD}" "${HOME}/.vnc/passwd" </dev/null
  X11VNC_COMMON+=(-rfbauth "${HOME}/.vnc/passwd")
else
  X11VNC_COMMON+=(-nopw)
fi

"${X11VNC_COMMON[@]}" &
X11VNC_PID=$!

sleep 0.5

websockify --web /usr/share/novnc "${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" &
WEBSOCKIFY_PID=$!

sleep 0.3
echo "[entrypoint-vnc] noVNC: http://0.0.0.0:${NOVNC_PORT}/ (Leagent live view :6080)"
echo "[entrypoint-vnc] Chromium: Leagent bootstraps /usr/bin/chromium on CDP 9223"

wait "${XVFB_PID}"
