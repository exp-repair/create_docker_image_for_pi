#!/bin/sh
# Chromium on this desktop. One profile and one CDP port per X display, so an
# Agent screen does not steal the shared desktop's window. CDP stays on
# loopback; the page itself is the window on this display.
set -eu

display="${DISPLAY:-:1}"
number="${display#:}"
number="${number%%.*}"
case "$number" in
  ''|*[!0-9]*) number=1 ;;
esac
port=$((9222 + number))
dir="${HOME}/.config/coforge-chromium/${number}"
mkdir -p "$dir"

exec /usr/bin/chromium \
  --no-sandbox \
  --disable-dev-shm-usage \
  --disable-gpu \
  --start-maximized \
  --user-data-dir="$dir" \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port="$port" \
  "$@"
