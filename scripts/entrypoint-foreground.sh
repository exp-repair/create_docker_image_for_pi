#!/usr/bin/env bash
# Docker rebuilds /etc/hosts when a container starts, so the build-time hosts
# line never survives. Pi runs inside the compiled coforge-computer binary and
# does not use the Node DNS hook, so Aimaster / ModelFactory names have to be here.
set -euo pipefail

pin_host() {
  local host="$1"
  local ip="$2"
  [[ -n "${host}" && -n "${ip}" && -w /etc/hosts ]] || return 0
  if ! grep -Eq "(^|[[:space:]])${host}([[:space:]]|$)" /etc/hosts; then
    printf '%s %s\n' "${ip}" "${host}" >> /etc/hosts
  fi
}

pin_host "${LENOVO_BRAIMASTER_HOST:-braimaster.lenovo.com}" "${LENOVO_BRAIMASTER_IP:-10.46.124.101}"
pin_host "${LENOVO_MODELFACTORY_HOST:-modelfactory.lenovo.com}" "${LENOVO_MODELFACTORY_IP:-10.110.158.101}"

# Image WORKDIR is /workspace. Leave it before persist may replace that path,
# otherwise this process (and every child) hits getcwd() failures.
cd / || true

if [[ -x /usr/local/bin/persist-user-data.sh ]]; then
  /usr/local/bin/persist-user-data.sh || echo "[entrypoint] persist-user-data.sh failed" >&2
  # Agent tool shells inherit this process env; keep venv pip/python first.
  if [[ -x /root/.coforge/venv/bin/python ]]; then
    export VIRTUAL_ENV=/root/.coforge/venv
    export PATH="/root/.coforge/venv/bin:${PATH}"
  fi
  export PIP_INDEX_URL="${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
  export PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-mirrors.aliyun.com}"
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD="${PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD:-1}"
  if ! mountpoint -q /opt 2>/dev/null; then
    /usr/local/bin/persist-user-data.sh --watch >/tmp/persist-user-data-watch.log 2>&1 &
  fi
fi

# Cloud-computer marker for CoForge (must stay unset on non-cloud hosts).
export COFORGE_CLOUD_COMPUTER="${COFORGE_CLOUD_COMPUTER:-1}"

# After /workspace is durable: seed/sync Pi skills, then bind-mount so newly
# created container-level skills land on the persistent volume automatically.
if [[ -x /usr/local/bin/sync-pi-skills.sh ]]; then
  /usr/local/bin/sync-pi-skills.sh || echo "[entrypoint] sync-pi-skills.sh failed" >&2
fi
if [[ -x /usr/local/bin/bind-pi-skills.sh ]]; then
  /usr/local/bin/bind-pi-skills.sh || echo "[entrypoint] bind-pi-skills.sh failed" >&2
fi

cd /workspace 2>/dev/null || cd / || true

# Corporate / Lenovo intranet: trust is baked (CA); proxy address is runtime.
if [[ -x /usr/local/bin/render-lenovo-proxy.sh ]]; then
  /usr/local/bin/render-lenovo-proxy.sh || echo "[entrypoint] render-lenovo-proxy.sh failed" >&2
  if [[ -f /etc/coforge/corp-proxy.env ]]; then
    # shellcheck disable=SC1091
    set -a
    # shellcheck disable=SC1091
    . /etc/coforge/corp-proxy.env
    set +a
  fi
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

# After an image replace, foreground recovers bindings once; if that handshake
# misses, the Workspace stays down. This watcher re-runs start until cloud is
# connected again (parked Workspaces are left alone).
if [[ "${COFORGE_WORKSPACE_WATCH:-1}" != "0" && -x /usr/local/bin/watch-computer-workspaces.sh ]]; then
  /usr/local/bin/watch-computer-workspaces.sh >/tmp/watch-computer-workspaces.log 2>&1 &
fi

# The supervisor stays up and runs the selected program as a child, so a
# runtime upgrade can replace that program without recreating the container.
# Seeding and selection happen when the child starts.
exec /usr/local/bin/supervise-computer-runtime.sh
