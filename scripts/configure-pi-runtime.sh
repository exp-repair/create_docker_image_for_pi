#!/usr/bin/env bash
# Configure Pi provider credentials from runtime environment, not image layers.
set -euo pipefail

log() { echo "[configure-pi-runtime] $*"; }

PI_USER="${PI_USER:-user}"
PI_HOME="${PI_HOME:-/home/${PI_USER}}"
AGENT_DIR="${PI_AGENT_DIR:-${PI_HOME}/.pi/agent}"
MODELS_FILE="${AGENT_DIR}/models.json"
SETTINGS_FILE="${AGENT_DIR}/settings.json"
TEAM_BASE_URL="${TEAM_BASE_URL:-https://claude-code.club/openai/v1}"
TEAM_MODEL="${TEAM_MODEL:-gpt-5.5}"
AREAL_BASE_URL="${AREAL_BASE_URL:-http://10.110.158.143:9100/v1}"
AREAL_API="${AREAL_API:-openai-completions}"
AREAL_API_KEY="${AREAL_API_KEY:-bridge}"
BRIDGE_USER_ID="${BRIDGE_USER_ID:-}"

if [[ -z "${TEAM_API_KEY:-}" ]]; then
  log "WARN: TEAM_API_KEY is empty; Pi may still need an API key"
fi
if [[ -z "${BRIDGE_USER_ID}" ]]; then
  log "WARN: BRIDGE_USER_ID is empty; areal.headers.X-Bridge-User-Id will be blank"
fi

mkdir -p "${AGENT_DIR}"

if command -v node >/dev/null 2>&1; then
  PI_MODELS_FILE="${MODELS_FILE}" \
  PI_SETTINGS_FILE="${SETTINGS_FILE}" \
  TEAM_API_KEY="${TEAM_API_KEY:-}" \
  TEAM_BASE_URL="${TEAM_BASE_URL}" \
  TEAM_MODEL="${TEAM_MODEL}" \
  BRIDGE_USER_ID="${BRIDGE_USER_ID}" \
  AREAL_BASE_URL="${AREAL_BASE_URL}" \
  AREAL_API="${AREAL_API}" \
  AREAL_API_KEY="${AREAL_API_KEY}" \
  node <<'NODE'
const fs = require("node:fs");

function readJson(path) {
  try {
    return fs.existsSync(path) ? JSON.parse(fs.readFileSync(path, "utf8")) : {};
  } catch {
    return {};
  }
}

function buildAreal() {
  return {
    baseUrl: process.env.AREAL_BASE_URL || "http://10.110.158.143:9100/v1",
    api: process.env.AREAL_API || "openai-completions",
    apiKey: process.env.AREAL_API_KEY || "bridge",
    headers: {
      "X-Bridge-User-Id": process.env.BRIDGE_USER_ID || "",
    },
    compat: {
      supportsDeveloperRole: false,
      supportsReasoningEffort: false,
    },
    models: [
      { id: "areal-distill" },
      { id: "areal-default" },
    ],
  };
}

const modelsPath = process.env.PI_MODELS_FILE;
const settingsPath = process.env.PI_SETTINGS_FILE;
const apiKey = process.env.TEAM_API_KEY || "";
const baseUrl = process.env.TEAM_BASE_URL;
const model = process.env.TEAM_MODEL;

const models = readJson(modelsPath);
const providers = models.providers && typeof models.providers === "object" ? models.providers : {};
const openai = providers.openai && typeof providers.openai === "object" ? providers.openai : {};
providers.openai = { ...openai, baseUrl };
if (apiKey) {
  providers.openai.apiKey = apiKey;
} else {
  delete providers.openai.apiKey;
}

const next = { ...models, providers, areal: buildAreal() };
fs.writeFileSync(modelsPath, `${JSON.stringify(next, null, 2)}\n`);

const settings = readJson(settingsPath);
fs.writeFileSync(settingsPath, `${JSON.stringify({
  ...settings,
  defaultProvider: "openai",
  defaultModel: model,
  theme: settings.theme ?? "light",
}, null, 2)}\n`);
NODE
elif command -v python3 >/dev/null 2>&1; then
  PI_MODELS_FILE="${MODELS_FILE}" \
  PI_SETTINGS_FILE="${SETTINGS_FILE}" \
  TEAM_API_KEY="${TEAM_API_KEY:-}" \
  TEAM_BASE_URL="${TEAM_BASE_URL}" \
  TEAM_MODEL="${TEAM_MODEL}" \
  BRIDGE_USER_ID="${BRIDGE_USER_ID}" \
  AREAL_BASE_URL="${AREAL_BASE_URL}" \
  AREAL_API="${AREAL_API}" \
  AREAL_API_KEY="${AREAL_API_KEY}" \
  python3 <<'PY'
import json
import os
from pathlib import Path


def read_json(path: Path):
    try:
        return json.loads(path.read_text()) if path.exists() else {}
    except Exception:
        return {}


def build_areal():
    return {
        "baseUrl": os.environ.get("AREAL_BASE_URL", "http://10.110.158.143:9100/v1"),
        "api": os.environ.get("AREAL_API", "openai-completions"),
        "apiKey": os.environ.get("AREAL_API_KEY", "bridge"),
        "headers": {
            "X-Bridge-User-Id": os.environ.get("BRIDGE_USER_ID", ""),
        },
        "compat": {
            "supportsDeveloperRole": False,
            "supportsReasoningEffort": False,
        },
        "models": [
            {"id": "areal-distill"},
            {"id": "areal-default"},
        ],
    }

models_path = Path(os.environ["PI_MODELS_FILE"])
settings_path = Path(os.environ["PI_SETTINGS_FILE"])
api_key = os.environ.get("TEAM_API_KEY", "")
base_url = os.environ["TEAM_BASE_URL"]
model = os.environ["TEAM_MODEL"]

models = read_json(models_path)
providers = models.get("providers") if isinstance(models.get("providers"), dict) else {}
openai = providers.get("openai") if isinstance(providers.get("openai"), dict) else {}
openai = {**openai, "baseUrl": base_url}
if api_key:
    openai["apiKey"] = api_key
else:
    openai.pop("apiKey", None)
providers["openai"] = openai
models["providers"] = providers
models["areal"] = build_areal()
models_path.write_text(json.dumps(models, indent=2) + "\n")

settings = read_json(settings_path)
settings.update({"defaultProvider": "openai", "defaultModel": model})
settings.setdefault("theme", "light")
settings_path.write_text(json.dumps(settings, indent=2) + "\n")
PY
else
  log "ERROR: node or python3 is required to write Pi config" >&2
  exit 1
fi

if [[ "$(id -u)" == "0" ]] && id "${PI_USER}" >/dev/null 2>&1; then
  chown -R "${PI_USER}:${PI_USER}" "${AGENT_DIR}"
fi

log "configured provider=openai baseUrl=${TEAM_BASE_URL} model=${TEAM_MODEL} areal.baseUrl=${AREAL_BASE_URL} bridgeUserId=${BRIDGE_USER_ID:-<empty>}"
