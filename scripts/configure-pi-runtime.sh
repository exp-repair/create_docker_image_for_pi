#!/usr/bin/env bash
# Configure Pi provider credentials from runtime environment, not image layers.
# Prefers TEAM_PI_CONFIG (multi-provider JSON). Falls back to TEAM_* flat env
# for older Multica / sandboxd builds.
#
# When LENOVO_DEEPSEEK_V4_FLASH_API_KEY is set, also merges Lenovo ModelFactory
# DeepSeek-V4-Flash into models.json and (by default) makes it the Pi default.
set -euo pipefail

log() { echo "[configure-pi-runtime] $*"; }

PI_USER="${PI_USER:-root}"
PI_HOME="${PI_HOME:-/root}"
AGENT_DIR="${PI_AGENT_DIR:-${PI_HOME}/.pi/agent}"
MODELS_FILE="${AGENT_DIR}/models.json"
SETTINGS_FILE="${AGENT_DIR}/settings.json"
CERTS_DIR="${AGENT_DIR}/certs"
CA_CERT_FILE="${LENOVO_MODELFACTORY_CA_CERT:-${CERTS_DIR}/lenovo-modelfactory-ca.pem}"
MODEL_FACTORY_ENV_FILE="${LENOVO_MODEL_FACTORY_ENV_FILE:-${AGENT_DIR}/model-factory.env}"
TEAM_BASE_URL="${TEAM_BASE_URL:-https://claude-code.club/openai/v1}"
TEAM_MODEL="${TEAM_MODEL:-gpt-5.5}"
TEAM_PROVIDER="${TEAM_PROVIDER:-openai}"
TEAM_API="${TEAM_API:-openai-responses}"
AREAL_BASE_URL="${AREAL_BASE_URL:-http://10.110.158.143:9100}"
AREAL_API="${AREAL_API:-openai-completions}"
AREAL_API_KEY="${AREAL_API_KEY:-bridge}"
BRIDGE_USER_ID="${BRIDGE_USER_ID:-}"

LENOVO_DEEPSEEK_PROVIDER="${LENOVO_DEEPSEEK_PROVIDER:-openai}"
LENOVO_DEEPSEEK_MODEL="${LENOVO_DEEPSEEK_MODEL:-DeepSeek}"
LENOVO_DEEPSEEK_BASE_URL="${LENOVO_DEEPSEEK_BASE_URL:-https://modelfactory.lenovo.com/llm/v1}"
LENOVO_DEEPSEEK_MODEL_NAME="${LENOVO_DEEPSEEK_MODEL_NAME:-DeepSeek}"
PI_MODELFACTORY_TEMPLATE="${PI_MODELFACTORY_TEMPLATE:-/usr/local/share/coforge/pi-modelfactory-provider.json}"
LENOVO_MODELFACTORY_HOST="${LENOVO_MODELFACTORY_HOST:-modelfactory.lenovo.com}"
LENOVO_MODELFACTORY_IP="${LENOVO_MODELFACTORY_IP:-10.110.158.101}"
LENOVO_DEEPSEEK_AS_DEFAULT="${LENOVO_DEEPSEEK_AS_DEFAULT:-1}"
LENOVO_DEEPSEEK_V4_FLASH_API_KEY="${LENOVO_DEEPSEEK_V4_FLASH_API_KEY:-}"

# Prefer image-baked key when runtime env did not inject one.
if [[ -z "${LENOVO_DEEPSEEK_V4_FLASH_API_KEY}" && -f "${MODEL_FACTORY_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1090
  source "${MODEL_FACTORY_ENV_FILE}"
  set +a
  LENOVO_DEEPSEEK_V4_FLASH_API_KEY="${LENOVO_DEEPSEEK_V4_FLASH_API_KEY:-}"
fi

ensure_lenovo_ca() {
  mkdir -p "${CERTS_DIR}"
  if [[ ! -f "${CA_CERT_FILE}" ]]; then
    if [[ -f /root/.pi/agent/certs/lenovo-modelfactory-ca.pem && "${CA_CERT_FILE}" != /root/.pi/agent/certs/lenovo-modelfactory-ca.pem ]]; then
      cp /root/.pi/agent/certs/lenovo-modelfactory-ca.pem "${CA_CERT_FILE}"
    else
      log "WARN: Lenovo CA missing at ${CA_CERT_FILE}"
      return 0
    fi
  fi
  chmod 644 "${CA_CERT_FILE}" || true
  export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-${CA_CERT_FILE}}"
  # Keep interactive shells / later Pi processes trusting the CA without curl -k.
  if [[ -d /etc/profile.d && -w /etc/profile.d ]]; then
    printf '%s\n' \
      "export NODE_EXTRA_CA_CERTS=\"\${NODE_EXTRA_CA_CERTS:-${CA_CERT_FILE}}\"" \
      > /etc/profile.d/lenovo-modelfactory-ca.sh \
      || log "WARN: could not write /etc/profile.d/lenovo-modelfactory-ca.sh"
    chmod 644 /etc/profile.d/lenovo-modelfactory-ca.sh 2>/dev/null || true
  fi
  if [[ -w "${PI_HOME}" ]] && { [[ -f "${PI_HOME}/.bashrc" ]] || touch "${PI_HOME}/.bashrc" 2>/dev/null; }; then
    if ! grep -q 'NODE_EXTRA_CA_CERTS=.*lenovo-modelfactory-ca.pem' "${PI_HOME}/.bashrc" 2>/dev/null; then
      printf '\n# Lenovo ModelFactory CA for Pi/Node TLS\nexport NODE_EXTRA_CA_CERTS="%s"\n' \
        "${CA_CERT_FILE}" >> "${PI_HOME}/.bashrc" || true
    fi
  fi
}
ensure_lenovo_dns() {
  local host="${LENOVO_MODELFACTORY_HOST}"
  local ip="${LENOVO_MODELFACTORY_IP}"
  [[ -n "${host}" && -n "${ip}" ]] || return 0
  # Cube sandboxes mount /etc/hosts as read-only tmpfs; Node uses
  # /usr/local/lib/lenovo-modelfactory-dns-hook.js instead.
  if [[ ! -w /etc/hosts ]]; then
    log "WARN: /etc/hosts is read-only; relying on NODE DNS hook for ${host} -> ${ip}"
    return 0
  fi
  if grep -Eq "^[[:space:]]*${ip//./\\.}[[:space:]]+.*[[:space:]]${host}([[:space:]]|\$)" /etc/hosts \
    || grep -Eq "^[[:space:]]*[0-9.]+[[:space:]]+.*[[:space:]]${host}([[:space:]]|\$)" /etc/hosts; then
    # Replace any existing mapping for this hostname so stale DNS does not win.
    local tmp
    tmp="$(mktemp)"
    awk -v h="${host}" -v ip="${ip}" '
      $0 ~ /^[[:space:]]*#/ { print; next }
      {
        found=0
        for (i=2; i<=NF; i++) if ($i == h) found=1
        if (found) next
        print
      }
      END { print ip " " h }
    ' /etc/hosts > "${tmp}"
    cat "${tmp}" > /etc/hosts
    rm -f "${tmp}"
  else
    printf '%s %s\n' "${ip}" "${host}" >> /etc/hosts
  fi
  log "dns ${host} -> ${ip} (/etc/hosts)"
}

write_model_factory_env() {
  local key="${LENOVO_DEEPSEEK_V4_FLASH_API_KEY}"
  [[ -n "${key}" ]] || return 0
  mkdir -p "${AGENT_DIR}"
  umask 077
  cat > "${MODEL_FACTORY_ENV_FILE}" <<EOF
LENOVO_DEEPSEEK_V4_FLASH_API_KEY=${key}
EOF
  chmod 600 "${MODEL_FACTORY_ENV_FILE}"
  log "wrote ${MODEL_FACTORY_ENV_FILE}"
}

if [[ -z "${TEAM_PI_CONFIG:-}" && -z "${TEAM_API_KEY:-}" && -z "${LENOVO_DEEPSEEK_V4_FLASH_API_KEY}" ]]; then
  log "WARN: TEAM_PI_CONFIG / TEAM_API_KEY / LENOVO_DEEPSEEK_V4_FLASH_API_KEY are empty; Pi may still need an API key"
fi
if [[ -z "${BRIDGE_USER_ID}" ]]; then
  log "WARN: BRIDGE_USER_ID is empty; areal.headers.X-Bridge-User-Id will be blank"
fi

mkdir -p "${AGENT_DIR}"
ensure_lenovo_ca
ensure_lenovo_dns
write_model_factory_env

if command -v node >/dev/null 2>&1; then
  PI_MODELS_FILE="${MODELS_FILE}" \
  PI_SETTINGS_FILE="${SETTINGS_FILE}" \
  TEAM_PI_CONFIG="${TEAM_PI_CONFIG:-}" \
  TEAM_API_KEY="${TEAM_API_KEY:-}" \
  TEAM_BASE_URL="${TEAM_BASE_URL}" \
  TEAM_MODEL="${TEAM_MODEL}" \
  TEAM_PROVIDER="${TEAM_PROVIDER}" \
  TEAM_API="${TEAM_API}" \
  BRIDGE_USER_ID="${BRIDGE_USER_ID}" \
  AREAL_BASE_URL="${AREAL_BASE_URL}" \
  AREAL_API="${AREAL_API}" \
  AREAL_API_KEY="${AREAL_API_KEY}" \
  LENOVO_DEEPSEEK_V4_FLASH_API_KEY="${LENOVO_DEEPSEEK_V4_FLASH_API_KEY}" \
  LENOVO_DEEPSEEK_PROVIDER="${LENOVO_DEEPSEEK_PROVIDER}" \
  LENOVO_DEEPSEEK_MODEL="${LENOVO_DEEPSEEK_MODEL}" \
  LENOVO_DEEPSEEK_BASE_URL="${LENOVO_DEEPSEEK_BASE_URL}" \
  LENOVO_DEEPSEEK_MODEL_NAME="${LENOVO_DEEPSEEK_MODEL_NAME}" \
  LENOVO_DEEPSEEK_AS_DEFAULT="${LENOVO_DEEPSEEK_AS_DEFAULT}" \
  LENOVO_MODEL_FACTORY_ENV_FILE="${MODEL_FACTORY_ENV_FILE}" \
  PI_MODELFACTORY_TEMPLATE="${PI_MODELFACTORY_TEMPLATE}" \
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
  const defaultApi = String(process.env.TEAM_API || "openai-responses").trim() || "openai-responses";
  const raw = (process.env.TEAM_PI_CONFIG || "").trim();
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      const providers = Array.isArray(parsed.providers) ? parsed.providers : [];
      const list = providers
        .map((p) => ({
          name: String(p.name || p.provider || "openai").trim() || "openai",
          api: String(p.api || defaultApi).trim() || defaultApi,
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
      api: defaultApi,
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
  if (entry.api) existing.api = entry.api;
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

function mergeLenovoDeepseek(providers) {
  const apiKey = String(process.env.LENOVO_DEEPSEEK_V4_FLASH_API_KEY || "").trim();
  if (!apiKey) return false;
  const name = String(process.env.LENOVO_DEEPSEEK_PROVIDER || "openai").trim() || "openai";
  const modelId = String(process.env.LENOVO_DEEPSEEK_MODEL || "DeepSeek").trim() || "DeepSeek";
  const templatePath = String(process.env.PI_MODELFACTORY_TEMPLATE || "").trim();
  const template = templatePath && fs.existsSync(templatePath) ? readJson(templatePath) : {};
  providers[name] = {
    baseUrl: String(process.env.LENOVO_DEEPSEEK_BASE_URL || template.baseUrl || "").trim(),
    api: template.api || "openai-completions",
    apiKey,
    compat: template.compat || {
      supportsDeveloperRole: false,
      thinkingFormat: "chat-template",
      chatTemplateKwargs: {
        reasoning_effort: { $var: "thinking.effort" },
      },
    },
    models: Array.isArray(template.models) && template.models.length > 0 ? template.models : [
      {
        id: modelId,
        name: String(process.env.LENOVO_DEEPSEEK_MODEL_NAME || "DeepSeek").trim(),
        reasoning: true,
        input: ["text"],
        contextWindow: 128000,
        maxTokens: 8192,
      },
    ],
  };
  return { name, modelId };
}

const modelsPath = process.env.PI_MODELS_FILE;
const settingsPath = process.env.PI_SETTINGS_FILE;
const cfg = normalizeConfig();

const models = readJson(modelsPath);
const providers = models.providers && typeof models.providers === "object" ? { ...models.providers } : {};
for (const entry of cfg.providers) {
  // Only write TEAM_* providers when credentials/config were actually supplied.
  const hasTeamCreds = Boolean(String(process.env.TEAM_API_KEY || "").trim())
    || Boolean(String(process.env.TEAM_PI_CONFIG || "").trim());
  if (!hasTeamCreds) continue;
  upsertProvider(providers, entry);
}

const lenovo = mergeLenovoDeepseek(providers);
const next = { ...models, providers, areal: buildAreal() };
fs.writeFileSync(modelsPath, `${JSON.stringify(next, null, 2)}\n`);
try { fs.chmodSync(modelsPath, 0o600); } catch {}

const settings = readJson(settingsPath);
const hasTeamCreds = Boolean(String(process.env.TEAM_API_KEY || "").trim())
  || Boolean(String(process.env.TEAM_PI_CONFIG || "").trim());
let defaultProvider = settings.defaultProvider || cfg.defaultProvider || "openai";
let defaultModel = settings.defaultModel || cfg.defaultModel || (cfg.providers[0] && cfg.providers[0].model) || "";
const asDefault = String(process.env.LENOVO_DEEPSEEK_AS_DEFAULT || "1").trim() !== "0";
if (lenovo && asDefault) {
  defaultProvider = lenovo.name;
  defaultModel = lenovo.modelId;
} else if (hasTeamCreds) {
  defaultProvider = cfg.defaultProvider || defaultProvider;
  defaultModel = cfg.defaultModel || defaultModel;
}
fs.writeFileSync(settingsPath, `${JSON.stringify({
  ...settings,
  defaultProvider,
  defaultModel,
  ...(lenovo && asDefault ? { defaultThinkingLevel: settings.defaultThinkingLevel || "high" } : {}),
  theme: settings.theme ?? "dark",
}, null, 2)}\n`);
try { fs.chmodSync(settingsPath, 0o600); } catch {}

const providerNames = Object.keys(providers).join(",");
console.log(`[configure-pi-runtime] providers=${providerNames} defaultProvider=${defaultProvider} defaultModel=${defaultModel}${lenovo ? " lenovo=on" : ""}`);
NODE
elif command -v python3 >/dev/null 2>&1; then
  PI_MODELS_FILE="${MODELS_FILE}" \
  PI_SETTINGS_FILE="${SETTINGS_FILE}" \
  TEAM_PI_CONFIG="${TEAM_PI_CONFIG:-}" \
  TEAM_API_KEY="${TEAM_API_KEY:-}" \
  TEAM_BASE_URL="${TEAM_BASE_URL}" \
  TEAM_MODEL="${TEAM_MODEL}" \
  TEAM_PROVIDER="${TEAM_PROVIDER}" \
  TEAM_API="${TEAM_API}" \
  BRIDGE_USER_ID="${BRIDGE_USER_ID}" \
  AREAL_BASE_URL="${AREAL_BASE_URL}" \
  AREAL_API="${AREAL_API}" \
  AREAL_API_KEY="${AREAL_API_KEY}" \
  LENOVO_DEEPSEEK_V4_FLASH_API_KEY="${LENOVO_DEEPSEEK_V4_FLASH_API_KEY}" \
  LENOVO_DEEPSEEK_PROVIDER="${LENOVO_DEEPSEEK_PROVIDER}" \
  LENOVO_DEEPSEEK_MODEL="${LENOVO_DEEPSEEK_MODEL}" \
  LENOVO_DEEPSEEK_BASE_URL="${LENOVO_DEEPSEEK_BASE_URL}" \
  LENOVO_DEEPSEEK_MODEL_NAME="${LENOVO_DEEPSEEK_MODEL_NAME}" \
  LENOVO_DEEPSEEK_AS_DEFAULT="${LENOVO_DEEPSEEK_AS_DEFAULT}" \
  LENOVO_MODEL_FACTORY_ENV_FILE="${MODEL_FACTORY_ENV_FILE}" \
  PI_MODELFACTORY_TEMPLATE="${PI_MODELFACTORY_TEMPLATE}" \
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
    default_api = str(os.environ.get("TEAM_API") or "openai-responses").strip() or "openai-responses"
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
                    "api": str(p.get("api") or default_api).strip() or default_api,
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
            "api": default_api,
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
    if entry.get("api"):
        existing["api"] = entry["api"]
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


def merge_lenovo_deepseek(providers):
    api_key = str(os.environ.get("LENOVO_DEEPSEEK_V4_FLASH_API_KEY") or "").strip()
    if not api_key:
        return None
    name = str(os.environ.get("LENOVO_DEEPSEEK_PROVIDER") or "openai").strip() or "openai"
    model_id = str(os.environ.get("LENOVO_DEEPSEEK_MODEL") or "DeepSeek").strip() or "DeepSeek"
    template = {}
    template_path = str(os.environ.get("PI_MODELFACTORY_TEMPLATE") or "").strip()
    if template_path and Path(template_path).exists():
        template = read_json(Path(template_path))
    providers[name] = {
        "baseUrl": str(os.environ.get("LENOVO_DEEPSEEK_BASE_URL") or template.get("baseUrl") or "").strip(),
        "api": template.get("api") or "openai-completions",
        "apiKey": api_key,
        "compat": template.get("compat") or {
            "supportsDeveloperRole": False,
            "thinkingFormat": "chat-template",
            "chatTemplateKwargs": {"reasoning_effort": {"$var": "thinking.effort"}},
        },
        "models": template.get("models") if isinstance(template.get("models"), list) and template.get("models") else [{
            "id": model_id,
            "name": str(os.environ.get("LENOVO_DEEPSEEK_MODEL_NAME") or "DeepSeek").strip(),
            "reasoning": True,
            "input": ["text"],
            "contextWindow": 128000,
            "maxTokens": 8192,
        }],
    }
    return {"name": name, "modelId": model_id}


models_path = Path(os.environ["PI_MODELS_FILE"])
settings_path = Path(os.environ["PI_SETTINGS_FILE"])
cfg = normalize_config()

models = read_json(models_path)
providers = dict(models["providers"]) if isinstance(models.get("providers"), dict) else {}
for entry in cfg["providers"]:
    has_team_creds = bool(str(os.environ.get("TEAM_API_KEY") or "").strip()) or bool(
        str(os.environ.get("TEAM_PI_CONFIG") or "").strip()
    )
    if not has_team_creds:
        continue
    upsert_provider(providers, entry)

lenovo = merge_lenovo_deepseek(providers)
models["providers"] = providers
models["areal"] = build_areal()
models_path.write_text(json.dumps(models, indent=2) + "\n")
try:
    models_path.chmod(0o600)
except Exception:
    pass

settings = read_json(settings_path)
has_team_creds = bool(str(os.environ.get("TEAM_API_KEY") or "").strip()) or bool(
    str(os.environ.get("TEAM_PI_CONFIG") or "").strip()
)
default_provider = settings.get("defaultProvider") or cfg.get("defaultProvider") or "openai"
default_model = settings.get("defaultModel") or cfg.get("defaultModel") or (
    cfg["providers"][0].get("model") if cfg["providers"] else ""
) or ""
as_default = str(os.environ.get("LENOVO_DEEPSEEK_AS_DEFAULT") or "1").strip() != "0"
if lenovo and as_default:
    default_provider = lenovo["name"]
    default_model = lenovo["modelId"]
elif has_team_creds:
    default_provider = cfg.get("defaultProvider") or default_provider
    default_model = cfg.get("defaultModel") or default_model
settings.update({"defaultProvider": default_provider, "defaultModel": default_model})
if lenovo and as_default:
    settings.setdefault("defaultThinkingLevel", "high")
settings.setdefault("theme", "dark")
settings_path.write_text(json.dumps(settings, indent=2) + "\n")
try:
    settings_path.chmod(0o600)
except Exception:
    pass
print(
    f"[configure-pi-runtime] providers={','.join(providers.keys())} "
    f"defaultProvider={default_provider} defaultModel={default_model}"
    f"{' lenovo=on' if lenovo else ''}"
)
PY
else
  log "ERROR: node or python3 is required to write Pi config" >&2
  exit 1
fi

if [[ "$(id -u)" == "0" ]] && [[ "${PI_USER}" != "root" ]] && id "${PI_USER}" >/dev/null 2>&1; then
  chown -R "${PI_USER}:${PI_USER}" "${AGENT_DIR}"
fi

log "configured TEAM_PI_CONFIG=${TEAM_PI_CONFIG:+set} TEAM_PROVIDER=${TEAM_PROVIDER} TEAM_API=${TEAM_API} TEAM_BASE_URL=${TEAM_BASE_URL} TEAM_MODEL=${TEAM_MODEL} areal.baseUrl=${AREAL_BASE_URL} bridgeUserId=${BRIDGE_USER_ID:-<empty>} lenovoKey=${LENOVO_DEEPSEEK_V4_FLASH_API_KEY:+set}"
