#!/usr/bin/env bash
# Configure Multica CLI/daemon from runtime environment, not image layers.
set -euo pipefail

log() { echo "[configure-multica-runtime] $*"; }

MULTICA_USER="${MULTICA_USER:-user}"
MULTICA_HOME="${MULTICA_HOME:-/home/${MULTICA_USER}}"
MULTICA_PROFILE="${MULTICA_PROFILE:-}"

if [[ -n "${MULTICA_PROFILE}" ]]; then
  CONFIG_DIR="${MULTICA_HOME}/.multica/profiles/${MULTICA_PROFILE}"
else
  CONFIG_DIR="${MULTICA_HOME}/.multica"
fi
CONFIG_FILE="${CONFIG_DIR}/config.json"

SERVER_URL="${MULTICA_SERVER_URL:-}"
APP_URL="${MULTICA_APP_URL:-}"
WORKSPACE_ID="${MULTICA_WORKSPACE_ID:-}"
TOKEN="${MULTICA_TOKEN:-}"

missing=()
[[ -n "${SERVER_URL}" ]] || missing+=(MULTICA_SERVER_URL)
[[ -n "${APP_URL}" ]] || missing+=(MULTICA_APP_URL)
[[ -n "${WORKSPACE_ID}" ]] || missing+=(MULTICA_WORKSPACE_ID)
[[ -n "${TOKEN}" ]] || missing+=(MULTICA_TOKEN)

if (( ${#missing[@]} > 0 )); then
  log "missing ${missing[*]}; not writing ${CONFIG_FILE}"
  exit 2
fi

mkdir -p "${CONFIG_DIR}"

if command -v node >/dev/null 2>&1; then
  MULTICA_CONFIG_FILE="${CONFIG_FILE}" \
  MULTICA_SERVER_URL="${SERVER_URL}" \
  MULTICA_APP_URL="${APP_URL}" \
  MULTICA_WORKSPACE_ID="${WORKSPACE_ID}" \
  MULTICA_TOKEN="${TOKEN}" \
  node <<'NODE'
const fs = require("node:fs");
const path = process.env.MULTICA_CONFIG_FILE;
let current = {};
try {
  if (fs.existsSync(path)) current = JSON.parse(fs.readFileSync(path, "utf8"));
} catch {}
const next = {
  ...current,
  server_url: process.env.MULTICA_SERVER_URL,
  app_url: process.env.MULTICA_APP_URL,
  workspace_id: process.env.MULTICA_WORKSPACE_ID,
  token: process.env.MULTICA_TOKEN,
};
fs.writeFileSync(path, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
NODE
elif command -v python3 >/dev/null 2>&1; then
  MULTICA_CONFIG_FILE="${CONFIG_FILE}" \
  MULTICA_SERVER_URL="${SERVER_URL}" \
  MULTICA_APP_URL="${APP_URL}" \
  MULTICA_WORKSPACE_ID="${WORKSPACE_ID}" \
  MULTICA_TOKEN="${TOKEN}" \
  python3 <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["MULTICA_CONFIG_FILE"])
try:
    current = json.loads(path.read_text()) if path.exists() else {}
except Exception:
    current = {}
current.update({
    "server_url": os.environ["MULTICA_SERVER_URL"],
    "app_url": os.environ["MULTICA_APP_URL"],
    "workspace_id": os.environ["MULTICA_WORKSPACE_ID"],
    "token": os.environ["MULTICA_TOKEN"],
})
path.write_text(json.dumps(current, indent=2) + "\n")
path.chmod(0o600)
PY
else
  log "ERROR: node or python3 is required to write Multica config" >&2
  exit 1
fi

chmod 600 "${CONFIG_FILE}"
if [[ "$(id -u)" == "0" ]] && id "${MULTICA_USER}" >/dev/null 2>&1; then
  chown -R "${MULTICA_USER}:${MULTICA_USER}" "${MULTICA_HOME}/.multica"
fi

log "configured ${CONFIG_FILE} server_url=${SERVER_URL} app_url=${APP_URL} workspace_id=${WORKSPACE_ID}"
