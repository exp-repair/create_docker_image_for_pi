#!/usr/bin/env bash
# Configure Pi provider credentials from runtime environment, not image layers.
# Prefers TEAM_PI_CONFIG (multi-provider JSON). Falls back to TEAM_* flat env
# for older Multica / sandboxd builds.
set -euo pipefail

log() { echo "[configure-pi-runtime] $*"; }

PI_USER="${PI_USER:-root}"
PI_HOME="${PI_HOME:-/root}"
AGENT_DIR="${PI_AGENT_DIR:-${PI_HOME}/.pi/agent}"
MODELS_FILE="${AGENT_DIR}/models.json"
SETTINGS_FILE="${AGENT_DIR}/settings.json"
TEAM_BASE_URL="${TEAM_BASE_URL:-https://claude-code.club/openai/v1}"
TEAM_MODEL="${TEAM_MODEL:-gpt-5.5}"
TEAM_PROVIDER="${TEAM_PROVIDER:-openai}"
AREAL_BASE_URL="${AREAL_BASE_URL:-http://10.110.158.143:9100}"
AREAL_API="${AREAL_API:-openai-completions}"
AREAL_API_KEY="${AREAL_API_KEY:-bridge}"
BRIDGE_USER_ID="${BRIDGE_USER_ID:-}"

if [[ -z "${TEAM_PI_CONFIG:-}" && -z "${TEAM_API_KEY:-}" ]]; then
  log "WARN: TEAM_PI_CONFIG and TEAM_API_KEY are empty; Pi may still need an API key"
fi
if [[ -z "${BRIDGE_USER_ID}" ]]; then
  log "WARN: BRIDGE_USER_ID is empty; areal.headers.X-Bridge-User-Id will be blank"
fi

mkdir -p "${AGENT_DIR}"

if command -v node >/dev/null 2>&1; then
  PI_MODELS_FILE="${MODELS_FILE}" \
  PI_SETTINGS_FILE="${SETTINGS_FILE}" \
  TEAM_PI_CONFIG="${TEAM_PI_CONFIG:-}" \
  TEAM_API_KEY="${TEAM_API_KEY:-}" \
  TEAM_BASE_URL="${TEAM_BASE_URL}" \
  TEAM_MODEL="${TEAM_MODEL}" \
  TEAM_PROVIDER="${TEAM_PROVIDER}" \
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
    baseUrl: process.env.AREAL_BASE_URL || "http://10.110.158.143:9100",
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

function normalizeConfig() {
  const raw = (process.env.TEAM_PI_CONFIG || "").trim();
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      const providers = Array.isArray(parsed.providers) ? parsed.providers : [];
      const list = providers
        .map((p) => ({
          name: String(p.name || p.provider || "openai").trim() || "openai",
          apiKey: String(p.apiKey || p.api_key || "").trim(),
          baseUrl: String(p.baseUrl || p.base_url || "").trim(),
          model: String(p.model || "").trim(),
        }))
        .filter((p) => p.name);
      if (list.length > 0) {
        return {
          providers: list,
          defaultProvider: String(parsed.defaultProvider || parsed.default_provider || list[0].name).trim() || list[0].name,
          defaultModel: String(parsed.defaultModel || parsed.default_model || list[0].model || "").trim(),
        };
      }
    } catch {
      // fall through to TEAM_* 
    }
  }
  const name = String(process.env.TEAM_PROVIDER || "openai").trim() || "openai";
  return {
    providers: [{
      name,
      apiKey: String(process.env.TEAM_API_KEY || "").trim(),
      baseUrl: String(process.env.TEAM_BASE_URL || "").trim(),
      model: String(process.env.TEAM_MODEL || "").trim(),
    }],
    defaultProvider: name,
    defaultModel: String(process.env.TEAM_MODEL || "").trim(),
  };
}

function upsertProvider(providers, entry) {
  const existing = providers[entry.name] && typeof providers[entry.name] === "object"
    ? { ...providers[entry.name] }
    : {};
  if (entry.baseUrl) existing.baseUrl = entry.baseUrl;
  if (entry.apiKey) {
    existing.apiKey = entry.apiKey;
  } else {
    delete existing.apiKey;
  }
  const models = Array.isArray(existing.models) ? [...existing.models] : [];
  if (entry.model) {
    const id = entry.model;
    if (!models.some((m) => m && m.id === id)) {
      models.push({ id });
    }
  }
  if (models.length > 0) existing.models = models;
  providers[entry.name] = existing;
}

const modelsPath = process.env.PI_MODELS_FILE;
const settingsPath = process.env.PI_SETTINGS_FILE;
const cfg = normalizeConfig();

const models = readJson(modelsPath);
const providers = models.providers && typeof models.providers === "object" ? { ...models.providers } : {};
for (const entry of cfg.providers) {
  upsertProvider(providers, entry);
}

const next = { ...models, providers, areal: buildAreal() };
fs.writeFileSync(modelsPath, `${JSON.stringify(next, null, 2)}\n`);

const settings = readJson(settingsPath);
const defaultProvider = cfg.defaultProvider || "openai";
const defaultModel = cfg.defaultModel || (cfg.providers[0] && cfg.providers[0].model) || "";
fs.writeFileSync(settingsPath, `${JSON.stringify({
  ...settings,
  defaultProvider,
  defaultModel,
  theme: settings.theme ?? "light",
}, null, 2)}\n`);

console.log(`[configure-pi-runtime] providers=${cfg.providers.map((p) => p.name).join(",")} defaultProvider=${defaultProvider} defaultModel=${defaultModel}`);
NODE
elif command -v python3 >/dev/null 2>&1; then
  PI_MODELS_FILE="${MODELS_FILE}" \
  PI_SETTINGS_FILE="${SETTINGS_FILE}" \
  TEAM_PI_CONFIG="${TEAM_PI_CONFIG:-}" \
  TEAM_API_KEY="${TEAM_API_KEY:-}" \
  TEAM_BASE_URL="${TEAM_BASE_URL}" \
  TEAM_MODEL="${TEAM_MODEL}" \
  TEAM_PROVIDER="${TEAM_PROVIDER}" \
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
        "baseUrl": os.environ.get("AREAL_BASE_URL", "http://10.110.158.143:9100"),
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


def normalize_config():
    raw = (os.environ.get("TEAM_PI_CONFIG") or "").strip()
    if raw:
        try:
            parsed = json.loads(raw)
            providers = parsed.get("providers") if isinstance(parsed.get("providers"), list) else []
            out = []
            for p in providers:
                if not isinstance(p, dict):
                    continue
                name = str(p.get("name") or p.get("provider") or "openai").strip() or "openai"
                out.append({
                    "name": name,
                    "apiKey": str(p.get("apiKey") or p.get("api_key") or "").strip(),
                    "baseUrl": str(p.get("baseUrl") or p.get("base_url") or "").strip(),
                    "model": str(p.get("model") or "").strip(),
                })
            if out:
                return {
                    "providers": out,
                    "defaultProvider": str(parsed.get("defaultProvider") or parsed.get("default_provider") or out[0]["name"]).strip() or out[0]["name"],
                    "defaultModel": str(parsed.get("defaultModel") or parsed.get("default_model") or out[0].get("model") or "").strip(),
                }
        except Exception:
            pass
    name = str(os.environ.get("TEAM_PROVIDER") or "openai").strip() or "openai"
    return {
        "providers": [{
            "name": name,
            "apiKey": str(os.environ.get("TEAM_API_KEY") or "").strip(),
            "baseUrl": str(os.environ.get("TEAM_BASE_URL") or "").strip(),
            "model": str(os.environ.get("TEAM_MODEL") or "").strip(),
        }],
        "defaultProvider": name,
        "defaultModel": str(os.environ.get("TEAM_MODEL") or "").strip(),
    }


def upsert_provider(providers, entry):
    existing = providers.get(entry["name"]) if isinstance(providers.get(entry["name"]), dict) else {}
    existing = dict(existing)
    if entry.get("baseUrl"):
        existing["baseUrl"] = entry["baseUrl"]
    if entry.get("apiKey"):
        existing["apiKey"] = entry["apiKey"]
    else:
        existing.pop("apiKey", None)
    models = list(existing["models"]) if isinstance(existing.get("models"), list) else []
    model = entry.get("model") or ""
    if model and not any(isinstance(m, dict) and m.get("id") == model for m in models):
        models.append({"id": model})
    if models:
        existing["models"] = models
    providers[entry["name"]] = existing


models_path = Path(os.environ["PI_MODELS_FILE"])
settings_path = Path(os.environ["PI_SETTINGS_FILE"])
cfg = normalize_config()

models = read_json(models_path)
providers = dict(models["providers"]) if isinstance(models.get("providers"), dict) else {}
for entry in cfg["providers"]:
    upsert_provider(providers, entry)
models["providers"] = providers
models["areal"] = build_areal()
models_path.write_text(json.dumps(models, indent=2) + "\n")

settings = read_json(settings_path)
default_provider = cfg.get("defaultProvider") or "openai"
default_model = cfg.get("defaultModel") or (cfg["providers"][0].get("model") if cfg["providers"] else "") or ""
settings.update({"defaultProvider": default_provider, "defaultModel": default_model})
settings.setdefault("theme", "light")
settings_path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"[configure-pi-runtime] providers={','.join(p['name'] for p in cfg['providers'])} defaultProvider={default_provider} defaultModel={default_model}")
PY
else
  log "ERROR: node or python3 is required to write Pi config" >&2
  exit 1
fi

if [[ "$(id -u)" == "0" ]] && [[ "${PI_USER}" != "root" ]] && id "${PI_USER}" >/dev/null 2>&1; then
  chown -R "${PI_USER}:${PI_USER}" "${AGENT_DIR}"
fi

log "configured TEAM_PI_CONFIG=${TEAM_PI_CONFIG:+set} TEAM_PROVIDER=${TEAM_PROVIDER} TEAM_BASE_URL=${TEAM_BASE_URL} TEAM_MODEL=${TEAM_MODEL} areal.baseUrl=${AREAL_BASE_URL} bridgeUserId=${BRIDGE_USER_ID:-<empty>}"
