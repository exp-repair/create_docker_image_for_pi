#!/usr/bin/env bash
# Coforge entrypoint: configure Pi, then serve the login-gated web terminal.
set -euo pipefail

export HOME="${HOME:-/root}"
export PATH="/root/.local/bin:/root/.npm-global/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-/root/.pi/agent/certs/lenovo-modelfactory-ca.pem}"
export NODE_OPTIONS="${NODE_OPTIONS:---require=/usr/local/lib/lenovo-modelfactory-dns-hook.js}"
export PI_WEB_HOST="${PI_WEB_HOST:-0.0.0.0}"
export PI_WEB_PORT="${PI_WEB_PORT:-6079}"
export PI_WEB_WORKSPACE="${PI_WEB_WORKSPACE:-/workspace}"
export PI_WEB_CONSOLE="${PI_WEB_CONSOLE:-0}"

/entrypoint-pi-web.sh &
exec /entrypoint-coforge-daemon.sh
