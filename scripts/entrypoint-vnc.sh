#!/usr/bin/env bash
# Xvfb (:0) + x11vnc (:5901) + noVNC (:6080).
# Optionally auto-opens Chromium on DISPLAY for noVNC (default: Baidu homepage).
set -euo pipefail

export HOME=/home/user

SCREEN_GEOM="${SCREEN_GEOM:-${RESOLUTION:-1920x1080x24}}"
VNC_PORT="${VNC_PORT:-5901}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
AUTO_START_BROWSER="${AUTO_START_BROWSER:-1}"
BROWSER_START_URL="${BROWSER_START_URL:-https://www.baidu.com}"
export DISPLAY="${DISPLAY:-:0}"

echo "[entrypoint-vnc] DISPLAY=${DISPLAY} SCREEN=${SCREEN_GEOM} VNC=${VNC_PORT} noVNC=${NOVNC_PORT}"

Xvfb "${DISPLAY}" -screen 0 "${SCREEN_GEOM}" -ac +extension RANDR +render -noreset &
XVFB_PID=$!

cleanup() {
  echo "[entrypoint-vnc] shutting down..."
  kill "${CHROMIUM_PID:-}" 2>/dev/null || true
  kill "${OPENBOX_PID:-}" 2>/dev/null || true
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

# Without a window manager, --start-maximized is ignored and Chromium stays ~945px wide.
openbox >/dev/null 2>&1 &
OPENBOX_PID=$!
sleep 0.3

resize_browser_window() {
  local width="${1:-1920}"
  local height="${2:-1080}"
  local best_wid="" best_area=0 wid w h area

  for _ in $(seq 1 40); do
    best_wid=""
    best_area=0
    while read -r wid; do
      [[ -z "${wid}" ]] && continue
      w=$(xdotool getwindowgeometry "${wid}" 2>/dev/null | awk '/Geometry:/ {print $2}' | cut -dx -f1)
      h=$(xdotool getwindowgeometry "${wid}" 2>/dev/null | awk '/Geometry:/ {print $2}' | cut -dx -f2)
      [[ -z "${w}" || -z "${h}" ]] && continue
      if (( w < 400 || h < 400 )); then
        continue
      fi
      area=$(( w * h ))
      if (( area > best_area )); then
        best_area=${area}
        best_wid=${wid}
      fi
    done < <(xdotool search --class chromium 2>/dev/null || true)

    if [[ -n "${best_wid}" ]]; then
      xdotool windowmove "${best_wid}" 0 0
      xdotool windowsize "${best_wid}" "${width}" "${height}"
      echo "[entrypoint-vnc] Chromium window ${best_wid} resized to ${width}x${height}"
      return 0
    fi
    sleep 0.5
  done

  echo "[entrypoint-vnc] WARN: could not resize Chromium window" >&2
  return 1
}

start_browser() {
  if [[ "${AUTO_START_BROWSER}" != "1" ]] || [[ -z "${BROWSER_START_URL}" ]]; then
    return 0
  fi
  if pgrep -x chromium >/dev/null 2>&1; then
    echo "[entrypoint-vnc] Chromium already running"
    return 0
  fi

  local width="${RESOLUTION_WIDTH:-1920}"
  local height="${RESOLUTION_HEIGHT:-1080}"
  echo "[entrypoint-vnc] starting Chromium (${width}x${height} desktop): ${BROWSER_START_URL}"
  chromium \
    --no-sandbox \
    --disable-gpu \
    --disable-dev-shm-usage \
    --start-maximized \
    --window-size="${width},${height}" \
    --window-position=0,0 \
    "${BROWSER_START_URL}" >/dev/null 2>&1 &
  CHROMIUM_PID=$!
  resize_browser_window "${width}" "${height}" &
}

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
start_browser
echo "[entrypoint-vnc] noVNC: http://0.0.0.0:${NOVNC_PORT}/ (Leagent live view :6080)"
if [[ "${AUTO_START_BROWSER}" == "1" ]] && [[ -n "${BROWSER_START_URL}" ]]; then
  echo "[entrypoint-vnc] Browser auto-start: ${BROWSER_START_URL}"
else
  echo "[entrypoint-vnc] Browser auto-start: disabled"
fi

wait "${XVFB_PID}"
