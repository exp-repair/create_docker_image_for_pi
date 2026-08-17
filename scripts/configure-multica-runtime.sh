#!/usr/bin/env bash
# Configure Multica CLI/daemon from runtime environment, not image layers.
#
# Equivalent headless substitute for:
#   multica setup /<workspace>
#   multica setup --environment test --server-url <api> --app-url <app> /<workspace>
# Interactive setup opens a browser for OAuth; Cube sandboxes cannot do that.
# Instead inject MULTICA_SERVER_URL / MULTICA_APP_URL / MULTICA_WORKSPACE_ID /
# MULTICA_TOKEN (and optional MULTICA_ENVIRONMENT=test) and write
# ~/.multica/config.json, pin Computer identity, then register a Workspace
# Binding (POST /api/computers/{id}/workspace-connections). Writing config
# alone is not enough: Computer stays running with 0 connections and the
# cloud UI shows offline.
set -euo pipefail

log() { echo "[configure-multica-runtime] $*"; }

MULTICA_USER="${MULTICA_USER:-root}"
MULTICA_HOME="${MULTICA_HOME:-/root}"
MULTICA_PROFILE="${MULTICA_PROFILE:-}"
ENVIRONMENT="$(printf '%s' "${MULTICA_ENVIRONMENT:-}" | tr '[:upper:]' '[:lower:]')"

# Computer is machine-wide and reads ~/.multica/config.json. Profile-scoped
# copies remain for older daemon binaries that still honor MULTICA_PROFILE.
MACHINE_CONFIG_DIR="${MULTICA_HOME}/.multica"
CONFIG_FILES=("${MACHINE_CONFIG_DIR}/config.json")
if [[ -n "${MULTICA_PROFILE}" ]]; then
  CONFIG_FILES+=("${MULTICA_HOME}/.multica/profiles/${MULTICA_PROFILE}/config.json")
fi

SERVER_URL="${MULTICA_SERVER_URL:-https://leagent.me}"
APP_URL="${MULTICA_APP_URL:-https://leagent.me}"
WORKSPACE_ID="${MULTICA_WORKSPACE_ID:-}"
TOKEN="${MULTICA_TOKEN:-}"

is_official_cloud_url() {
  local host
  host="$(printf '%s' "${1:-}" | sed -E 's#^https?://##' | cut -d/ -f1 | cut -d: -f1 | tr '[:upper:]' '[:lower:]')"
  case "${host}" in
    leagent.me|www.leagent.me|api.leagent.me) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ -z "${ENVIRONMENT}" ]]; then
  if is_official_cloud_url "${SERVER_URL}"; then
    ENVIRONMENT="production"
  else
    ENVIRONMENT="test"
    log "inferred MULTICA_ENVIRONMENT=test from non-production server_url=${SERVER_URL}"
  fi
fi

if [[ "${ENVIRONMENT}" == "test" ]]; then
  if is_official_cloud_url "${SERVER_URL}" || is_official_cloud_url "${APP_URL}"; then
    log "ERROR: MULTICA_ENVIRONMENT=test cannot use production hosts (leagent.me)" >&2
    log "hint: set MULTICA_SERVER_URL / MULTICA_APP_URL to the test origin, e.g. https://82.157.184.89" >&2
    exit 1
  fi
fi

missing=()
[[ -n "${SERVER_URL}" ]] || missing+=(MULTICA_SERVER_URL)
[[ -n "${APP_URL}" ]] || missing+=(MULTICA_APP_URL)
[[ -n "${WORKSPACE_ID}" ]] || missing+=(MULTICA_WORKSPACE_ID)
[[ -n "${TOKEN}" ]] || missing+=(MULTICA_TOKEN)

if (( ${#missing[@]} > 0 )); then
  log "missing ${missing[*]}; not writing Multica config"
  log "hint: for interactive hosts use: multica setup --environment ${ENVIRONMENT} --server-url ${SERVER_URL} --app-url ${APP_URL} /<workspace>"
  exit 2
fi

write_multica_config() {
  local config_file="$1"
  mkdir -p "$(dirname "${config_file}")"
  if command -v node >/dev/null 2>&1; then
    MULTICA_CONFIG_FILE="${config_file}" \
    MULTICA_SERVER_URL="${SERVER_URL}" \
    MULTICA_APP_URL="${APP_URL}" \
    MULTICA_WORKSPACE_ID="${WORKSPACE_ID}" \
    MULTICA_TOKEN="${TOKEN}" \
    MULTICA_ENVIRONMENT="${ENVIRONMENT}" \
    node <<'NODE'
const fs = require("node:fs");
const path = process.env.MULTICA_CONFIG_FILE;
const environment = (process.env.MULTICA_ENVIRONMENT || "").trim().toLowerCase();
let current = {};
try {
  if (fs.existsSync(path)) current = JSON.parse(fs.readFileSync(path, "utf8"));
} catch {}
const session = {
  server_url: process.env.MULTICA_SERVER_URL,
  app_url: process.env.MULTICA_APP_URL,
  workspace_id: process.env.MULTICA_WORKSPACE_ID,
  token: process.env.MULTICA_TOKEN,
};
const next = { ...current, ...session };
if (environment === "test" || environment === "production") {
  next.environment = environment;
  next.active_environment = environment;
  if (environment === "test") next.release_channel = "alpha";
  next.environments = {
    ...(current.environments && typeof current.environments === "object" ? current.environments : {}),
    [environment]: session,
  };
}
fs.writeFileSync(path, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
NODE
  elif command -v python3 >/dev/null 2>&1; then
    MULTICA_CONFIG_FILE="${config_file}" \
    MULTICA_SERVER_URL="${SERVER_URL}" \
    MULTICA_APP_URL="${APP_URL}" \
    MULTICA_WORKSPACE_ID="${WORKSPACE_ID}" \
    MULTICA_TOKEN="${TOKEN}" \
    MULTICA_ENVIRONMENT="${ENVIRONMENT}" \
    python3 <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["MULTICA_CONFIG_FILE"])
environment = (os.environ.get("MULTICA_ENVIRONMENT") or "").strip().lower()
try:
    current = json.loads(path.read_text()) if path.exists() else {}
except Exception:
    current = {}
session = {
    "server_url": os.environ["MULTICA_SERVER_URL"],
    "app_url": os.environ["MULTICA_APP_URL"],
    "workspace_id": os.environ["MULTICA_WORKSPACE_ID"],
    "token": os.environ["MULTICA_TOKEN"],
}
current.update(session)
if environment in ("test", "production"):
    current["environment"] = environment
    current["active_environment"] = environment
    if environment == "test":
        current["release_channel"] = "alpha"
    environments = current.get("environments")
    if not isinstance(environments, dict):
        environments = {}
    environments[environment] = session
    current["environments"] = environments
path.write_text(json.dumps(current, indent=2) + "\n")
path.chmod(0o600)
PY
  else
    log "ERROR: node or python3 is required to write Multica config" >&2
    return 1
  fi
  chmod 600 "${config_file}"
}

for config_file in "${CONFIG_FILES[@]}"; do
  write_multica_config "${config_file}"
  log "configured ${config_file} environment=${ENVIRONMENT} server_url=${SERVER_URL} app_url=${APP_URL} workspace_id=${WORKSPACE_ID}"
done

computer_is_running() {
  pgrep -f 'multica.*computer __service' >/dev/null 2>&1 \
    || pgrep -f 'multica.*daemon start --foreground' >/dev/null 2>&1
}

# Headless stand-in for `multica setup`: mint/pin Computer identity, then
# register the Workspace Execution Binding the resident actually connects with.
establish_workspace_binding() {
  if ! command -v python3 >/dev/null 2>&1; then
    log "ERROR: python3 is required to register the Workspace Binding" >&2
    return 1
  fi

  local running=0
  if computer_is_running; then
    running=1
  fi

  local identity
  local attempt
  local last_err=""
  for attempt in 1 2 3; do
    set +e
    identity="$(
      MULTICA_HOME="${MULTICA_HOME}" \
      MULTICA_SERVER_URL="${SERVER_URL}" \
      MULTICA_WORKSPACE_ID="${WORKSPACE_ID}" \
      MULTICA_TOKEN="${TOKEN}" \
      MULTICA_ENVIRONMENT="${ENVIRONMENT}" \
      MULTICA_DAEMON_ID="${MULTICA_DAEMON_ID:-}" \
      MULTICA_WORKSPACE_SLUG="${MULTICA_WORKSPACE_SLUG:-}" \
      MULTICA_COMPUTER_RUNNING="${running}" \
      python3 <<'PY'
import json
import os
import uuid
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

home = Path(os.environ["MULTICA_HOME"])
computer_dir = home / ".multica" / "computer"
computer_dir.mkdir(parents=True, exist_ok=True)
identity_path = computer_dir / "daemon.id"
legacy_identity_path = home / ".multica" / "daemon.id"


def valid_uuid(value: str) -> str:
    value = (value or "").strip()
    try:
        uuid.UUID(value)
    except Exception:
        return ""
    return value


def read_id(path: Path) -> str:
    try:
        return valid_uuid(path.read_text())
    except Exception:
        return ""


pinned = valid_uuid(os.environ.get("MULTICA_DAEMON_ID", ""))
existing = read_id(identity_path)
computer_running = os.environ.get("MULTICA_COMPUTER_RUNNING") == "1"

# A live resident already has its identity in memory. Do not rewrite the file
# out from under it. When Cube injects MULTICA_DAEMON_ID and the Computer is
# stopped, pin that id so the cloud "电脑" row is the one that comes online.
if computer_running and existing:
    identity = existing
elif pinned:
    identity = pinned
elif existing:
    identity = existing
else:
    identity = str(uuid.uuid4())

identity_path.write_text(identity + "\n")
identity_path.chmod(0o600)
legacy_identity_path.write_text(identity + "\n")
legacy_identity_path.chmod(0o600)

server = os.environ["MULTICA_SERVER_URL"].rstrip("/")
workspace_id = os.environ["MULTICA_WORKSPACE_ID"]
token = os.environ["MULTICA_TOKEN"]
environment = os.environ["MULTICA_ENVIRONMENT"]
slug = (os.environ.get("MULTICA_WORKSPACE_SLUG") or "").strip().lstrip("/")

req = urllib.request.Request(
    f"{server}/api/computers/{identity}/workspace-connections",
    data=json.dumps({"workspace_id": workspace_id}).encode(),
    method="POST",
    headers={
        "Authorization": "Bearer " + token,
        "X-Workspace-ID": workspace_id,
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-Client-Platform": "cli",
        "X-Client-OS": "linux",
    },
)
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        accepted = json.load(resp)
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", "replace")[:500]
    raise SystemExit(f"POST workspace-connections returned {exc.code}: {body}") from exc

if not accepted.get("ok") or accepted.get("workspace_id") != workspace_id or not accepted.get("credential"):
    raise SystemExit("server did not accept the selected Workspace connection")

bindings_path = computer_dir / "bindings.json"
try:
    bindings = json.loads(bindings_path.read_text()) if bindings_path.exists() else []
    if not isinstance(bindings, list):
        bindings = []
except Exception:
    bindings = []

entry = {
    "environment": environment,
    "origin": server,
    "workspace_id": workspace_id,
    "workspace_slug": slug,
    "computer_id": identity,
    "credential": accepted["credential"],
    "credential_expires_at": accepted.get("credential_expires_at") or "",
    "accepted_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
    "active": True,
}
out = []
replaced = False
for binding in bindings:
    if (
        isinstance(binding, dict)
        and binding.get("environment") == environment
        and binding.get("workspace_id") == workspace_id
    ):
        out.append(entry)
        replaced = True
    else:
        out.append(binding)
if not replaced:
    out.append(entry)
bindings_path.write_text(json.dumps(out, indent=2) + "\n")
bindings_path.chmod(0o600)
print(identity)
PY
    )"
    local code=$?
    set -e
    if [[ "${code}" -eq 0 && -n "${identity}" ]]; then
      log "registered Workspace Binding computer_id=${identity} workspace_id=${WORKSPACE_ID} environment=${ENVIRONMENT}"
      return 0
    fi
    last_err="${identity:-workspace binding failed}"
    log "WARN: Workspace Binding attempt ${attempt}/3 failed: ${last_err}"
    sleep 2
  done
  log "ERROR: could not register Workspace Binding; Computer will stay offline" >&2
  return 1
}

establish_workspace_binding

if [[ "$(id -u)" == "0" ]] && [[ "${MULTICA_USER}" != "root" ]] && id "${MULTICA_USER}" >/dev/null 2>&1; then
  chown -R "${MULTICA_USER}:${MULTICA_USER}" "${MULTICA_HOME}/.multica"
fi
