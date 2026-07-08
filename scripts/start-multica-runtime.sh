#!/usr/bin/env bash
# Dynamically configure Pi + Multica and start the Multica daemon for this sandbox.
set -euo pipefail

log() { echo "[start-multica-runtime] $*"; }

MULTICA_USER="${MULTICA_USER:-user}"
MULTICA_HOME="${MULTICA_HOME:-/home/${MULTICA_USER}}"
export HOME="${HOME:-${MULTICA_HOME}}"

resolve_sandbox_device_name() {
  if [[ -n "${MULTICA_DAEMON_DEVICE_NAME:-}" ]]; then
    return 0
  fi
  if [[ -n "${MULTICA_SANDBOX_NAME:-}" ]]; then
    export MULTICA_DAEMON_DEVICE_NAME="${MULTICA_SANDBOX_NAME}"
    return 0
  fi
  if [[ "${MULTICA_PROFILE:-}" != sandbox-* || -z "${MULTICA_SERVER_URL:-}" || -z "${MULTICA_WORKSPACE_ID:-}" || -z "${MULTICA_TOKEN:-}" ]]; then
    return 0
  fi

  local instance_id="${MULTICA_PROFILE#sandbox-}"
  local resolved
  resolved="$(MULTICA_SANDBOX_INSTANCE_ID="${instance_id}" python3 <<'PY' 2>/dev/null || true
import json
import os
import urllib.parse
import urllib.request

base = os.environ.get("MULTICA_SERVER_URL", "").rstrip("/")
workspace_id = os.environ.get("MULTICA_WORKSPACE_ID", "")
token = os.environ.get("MULTICA_TOKEN", "")
instance_id = os.environ.get("MULTICA_SANDBOX_INSTANCE_ID", "")
if not (base and workspace_id and token and instance_id):
    raise SystemExit(0)

url = base + "/api/sandboxes/" + urllib.parse.quote(instance_id, safe="")
req = urllib.request.Request(
    url,
    headers={
        "Authorization": "Bearer " + token,
        "X-Workspace-ID": workspace_id,
        "Accept": "application/json",
    },
)
with urllib.request.urlopen(req, timeout=8) as resp:
    data = json.load(resp)
metadata = data.get("metadata") or {}
if isinstance(metadata, str):
    try:
        metadata = json.loads(metadata)
    except Exception:
        metadata = {}
name = metadata.get("name") if isinstance(metadata, dict) else None
if isinstance(name, str) and name.strip():
    print(name.strip())
PY
)"
  resolved="$(printf '%s' "${resolved}" | tr '\r\n' ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ -n "${resolved}" ]]; then
    export MULTICA_SANDBOX_NAME="${resolved}"
    export MULTICA_DAEMON_DEVICE_NAME="${resolved}"
  fi
}

resolve_sandbox_device_name

if [[ "$(id -u)" == "0" && -n "${RUN_AS_USER:-1}" ]] && id "${MULTICA_USER}" >/dev/null 2>&1; then
  exec runuser -u "${MULTICA_USER}" -- env \
    HOME="${MULTICA_HOME}" \
    PATH="/home/${MULTICA_USER}/.npm-global/bin:/home/${MULTICA_USER}/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin" \
    TEAM_API_KEY="${TEAM_API_KEY:-}" \
    TEAM_BASE_URL="${TEAM_BASE_URL:-}" \
    TEAM_MODEL="${TEAM_MODEL:-}" \
    BRIDGE_USER_ID="${BRIDGE_USER_ID:-}" \
    AREAL_BASE_URL="${AREAL_BASE_URL:-}" \
    AREAL_API="${AREAL_API:-}" \
    AREAL_API_KEY="${AREAL_API_KEY:-}" \
    MULTICA_SERVER_URL="${MULTICA_SERVER_URL:-}" \
    MULTICA_APP_URL="${MULTICA_APP_URL:-}" \
    MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID:-}" \
    MULTICA_TOKEN="${MULTICA_TOKEN:-}" \
    MULTICA_PROFILE="${MULTICA_PROFILE:-}" \
    MULTICA_DAEMON_ENABLED="${MULTICA_DAEMON_ENABLED:-1}" \
    MULTICA_DAEMON_DEVICE_NAME="${MULTICA_DAEMON_DEVICE_NAME:-}" \
    MULTICA_SANDBOX_NAME="${MULTICA_SANDBOX_NAME:-}" \
    RUN_AS_USER= \
    /usr/local/bin/start-multica-runtime.sh "$@"
fi

mkdir -p "${MULTICA_HOME}/.multica"

if [[ -n "${TEAM_API_KEY:-}" || -n "${TEAM_BASE_URL:-}" || -n "${TEAM_MODEL:-}" || -n "${BRIDGE_USER_ID:-}" ]]; then
  configure-pi-runtime.sh
else
  log "TEAM_* not provided; leaving Pi config unchanged"
fi

configure-multica-runtime.sh

if command -v multica >/dev/null 2>&1; then
  multica daemon stop >/dev/null 2>&1 || true
fi
pkill -f "multica.*daemon start --foreground" >/dev/null 2>&1 || true

log "starting Multica daemon"
nohup /entrypoint-multica-daemon.sh >>"${MULTICA_HOME}/.multica/daemon.log" 2>&1 &

sleep 2
if pgrep -f "multica.*daemon start --foreground" >/dev/null 2>&1; then
  log "daemon process started"
else
  log "daemon process not running yet; check ${MULTICA_HOME}/.multica/daemon.log"
fi
