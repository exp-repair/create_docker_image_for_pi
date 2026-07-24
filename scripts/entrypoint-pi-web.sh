#!/usr/bin/env bash
# Start the Pi web bridge. It exposes a browser UI backed by `pi --mode rpc`.
set -euo pipefail

export HOME="${HOME:-/root}"
export PATH="/root/.npm-global/bin:/root/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
export PI_WEB_HOST="${PI_WEB_HOST:-0.0.0.0}"
export PI_WEB_PORT="${PI_WEB_PORT:-6079}"
export PI_WEB_WORKSPACE="${PI_WEB_WORKSPACE:-/workspace}"

if pgrep -f "/opt/pi-web/server.js" >/dev/null 2>&1; then
  echo "[entrypoint-pi-web] Pi web console already running"
  exec tail -f /dev/null
fi

if command -v configure-pi-runtime.sh >/dev/null 2>&1; then
  configure-pi-runtime.sh
fi

cd /opt/pi-web
exec node /opt/pi-web/server.js
