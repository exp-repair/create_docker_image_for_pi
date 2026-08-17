#!/usr/bin/env bash
# Dynamically configure Pi + Multica and start the Multica daemon for this sandbox.
set -euo pipefail

log() { echo "[start-multica-runtime] $*"; }

MULTICA_USER="${MULTICA_USER:-root}"
MULTICA_HOME="${MULTICA_HOME:-/root}"
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

# Stop the outer entrypoint loop first so it cannot revive the daemon while we
# reconfigure identity/token/profile, then stop Multica supervise/worker procs.
stop_multica_daemon_supervisor() {
  if command -v multica >/dev/null 2>&1; then
    # Alpha Computer is machine-wide and rejects --profile.
    multica computer stop >/dev/null 2>&1 || true
    multica daemon stop >/dev/null 2>&1 || true
    if [[ -n "${MULTICA_PROFILE:-}" ]]; then
      multica --profile "${MULTICA_PROFILE}" daemon stop >/dev/null 2>&1 || true
    fi
  fi
  pkill -f '/entrypoint-multica-daemon\.sh' >/dev/null 2>&1 || true
  pkill -f 'multica.*daemon supervise' >/dev/null 2>&1 || true
  pkill -f 'multica.*computer supervise' >/dev/null 2>&1 || true
  pkill -f 'multica.*daemon start --foreground' >/dev/null 2>&1 || true
  pkill -f 'multica.*computer start --foreground' >/dev/null 2>&1 || true
  sleep 1
}

multica_daemon_running() {
  pgrep -f 'multica.*daemon supervise' >/dev/null 2>&1 \
    || pgrep -f 'multica.*computer supervise' >/dev/null 2>&1 \
    || pgrep -f 'multica.*daemon start --foreground' >/dev/null 2>&1 \
    || pgrep -f 'multica.*computer start --foreground' >/dev/null 2>&1 \
    || pgrep -f '/entrypoint-multica-daemon\.sh' >/dev/null 2>&1
}

resolve_sandbox_device_name

export PATH="/root/.local/bin:/root/.npm-global/bin:/root/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
CURSOR_ENV_FILE="${CURSOR_ENV_FILE:-${MULTICA_HOME}/.cursor/runtime.env}"

mkdir -p "${MULTICA_HOME}/.multica"

# Halt any previous supervisor before rewriting runtime config.
stop_multica_daemon_supervisor

if [[ -n "${TEAM_PI_CONFIG:-}" || -n "${TEAM_API_KEY:-}" || -n "${TEAM_BASE_URL:-}" || -n "${TEAM_MODEL:-}" || -n "${TEAM_PROVIDER:-}" || -n "${BRIDGE_USER_ID:-}" || -n "${LENOVO_DEEPSEEK_V4_FLASH_API_KEY:-}" ]]; then
  configure-pi-runtime.sh
else
  log "TEAM_PI_CONFIG / TEAM_* / LENOVO_DEEPSEEK_V4_FLASH_API_KEY not provided; leaving Pi config unchanged"
fi

if command -v configure-cursor-runtime.sh >/dev/null 2>&1; then
  if [[ -n "${CURSOR_API_KEY:-}" || -n "${MULTICA_CURSOR_PATH:-}" || -n "${MULTICA_CURSOR_MODEL:-}" ]] \
    || command -v cursor-agent >/dev/null 2>&1 \
    || [[ -x /usr/local/bin/cursor-agent ]]; then
    configure-cursor-runtime.sh
  else
    log "cursor-agent not installed; skipping Cursor runtime configure"
  fi
fi
if [[ -f "${CURSOR_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CURSOR_ENV_FILE}"
fi

configure-multica-runtime.sh

stop_multica_daemon_supervisor

log "starting Multica daemon supervisor (daemon supervise + outer restart loop)"
nohup /entrypoint-multica-daemon.sh >>"${MULTICA_HOME}/.multica/daemon.log" 2>&1 &

sleep 2
if multica_daemon_running; then
  log "daemon supervisor started"
else
  log "daemon process not running yet; check ${MULTICA_HOME}/.multica/daemon.log"
fi

# Binding is re-read every ~5s; wait briefly so /execute logs show Connected.
waited=0
while (( waited < 20 )); do
  if command -v multica >/dev/null 2>&1 \
    && multica computer status 2>/dev/null | grep -Eq 'Connected:[[:space:]]*true'; then
    log "Computer connected to Workspace"
    break
  fi
  sleep 1
  waited=$((waited + 1))
done
if (( waited >= 20 )); then
  log "WARN: Computer did not report Connected=true within 20s; check ${MULTICA_HOME}/.multica/computer/bindings.json and computer status"
fi
