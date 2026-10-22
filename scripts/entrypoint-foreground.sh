#!/usr/bin/env bash
# Docker rebuilds /etc/hosts when a container starts, so the build-time hosts
# line never survives. Pi runs inside the compiled coforge-computer binary and
# does not use the Node DNS hook, so the ModelFactory name has to be here.
set -euo pipefail

host="${LENOVO_MODELFACTORY_HOST:-modelfactory.lenovo.com}"
ip="${LENOVO_MODELFACTORY_IP:-10.110.158.101}"
if [[ -n "${host}" && -n "${ip}" && -w /etc/hosts ]] && ! grep -Eq "(^|[[:space:]])${host}([[:space:]]|$)" /etc/hosts; then
  printf '%s %s\n' "${ip}" "${host}" >> /etc/hosts
fi

# The shared desktop stays down until a VNC or browser client connects.
# Each Agent's screen is started by vnc-websocket on demand, and held through
# 127.0.0.1:6091 while that Agent is running.
# VNC_ENABLE=0 skips both listeners. VNC_WS_ENABLE=0 keeps raw VNC only.
if [[ "${VNC_ENABLE:-1}" != "0" ]]; then
  /usr/local/bin/vnc-ondemand.py &
  if [[ "${VNC_WS_ENABLE:-1}" != "0" ]]; then
    /usr/local/bin/vnc-websocket.py &
  fi
fi

exec /usr/local/bin/coforge-computer foreground
