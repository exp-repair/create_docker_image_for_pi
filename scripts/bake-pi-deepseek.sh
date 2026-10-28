#!/usr/bin/env bash
# Bake Lenovo ModelFactory DeepSeek into Pi agent config (image build or runtime).
# Requires LENOVO_DEEPSEEK_V4_FLASH_API_KEY in the environment.
set -euo pipefail

log() { echo "[bake-pi-deepseek] $*"; }

PI_HOME="${PI_HOME:-/root}"
AGENT_DIR="${PI_AGENT_DIR:-${PI_HOME}/.pi/agent}"
MODELS_FILE="${AGENT_DIR}/models.json"
SETTINGS_FILE="${AGENT_DIR}/settings.json"
CERTS_DIR="${AGENT_DIR}/certs"
CA_CERT_FILE="${LENOVO_MODELFACTORY_CA_CERT:-${CERTS_DIR}/lenovo-modelfactory-ca.pem}"
MODEL_FACTORY_ENV_FILE="${LENOVO_MODEL_FACTORY_ENV_FILE:-${AGENT_DIR}/model-factory.env}"

LENOVO_DEEPSEEK_PROVIDER="${LENOVO_DEEPSEEK_PROVIDER:-openai}"
LENOVO_DEEPSEEK_MODEL="${LENOVO_DEEPSEEK_MODEL:-DeepSeek}"
LENOVO_DEEPSEEK_BASE_URL="${LENOVO_DEEPSEEK_BASE_URL:-https://modelfactory.lenovo.com/llm/v1}"
LENOVO_DEEPSEEK_MODEL_NAME="${LENOVO_DEEPSEEK_MODEL_NAME:-DeepSeek}"
PI_MODELFACTORY_TEMPLATE="${PI_MODELFACTORY_TEMPLATE:-/usr/local/share/coforge/pi-modelfactory-provider.json}"
LENOVO_MODELFACTORY_HOST="${LENOVO_MODELFACTORY_HOST:-modelfactory.lenovo.com}"
LENOVO_MODELFACTORY_IP="${LENOVO_MODELFACTORY_IP:-10.110.158.101}"
API_KEY="${LENOVO_DEEPSEEK_V4_FLASH_API_KEY:-}"

if [[ -z "${API_KEY}" ]]; then
  log "ERROR: LENOVO_DEEPSEEK_V4_FLASH_API_KEY is required" >&2
  exit 1
fi

mkdir -p "${AGENT_DIR}" "${CERTS_DIR}"

APPEND_SYSTEM_TEMPLATE="${PI_APPEND_SYSTEM_TEMPLATE:-/usr/local/share/coforge/pi-APPEND_SYSTEM.md}"
if [[ -f "${APPEND_SYSTEM_TEMPLATE}" ]]; then
  cp "${APPEND_SYSTEM_TEMPLATE}" "${AGENT_DIR}/APPEND_SYSTEM.md"
  chmod 644 "${AGENT_DIR}/APPEND_SYSTEM.md" || true
  log "installed APPEND_SYSTEM.md from ${APPEND_SYSTEM_TEMPLATE}"
elif [[ ! -f "${AGENT_DIR}/APPEND_SYSTEM.md" ]]; then
  log "WARN: APPEND_SYSTEM template missing at ${APPEND_SYSTEM_TEMPLATE}"
fi

SKILLS_TEMPLATE="${PI_SKILLS_TEMPLATE:-/usr/local/share/coforge/pi-skills}"
SKILLS_DIR="${AGENT_DIR}/skills"
if [[ -d "${SKILLS_TEMPLATE}" ]]; then
  mkdir -p "${SKILLS_DIR}"
  for skill_name in cloud-computer-overview browser-login; do
    if [[ -d "${SKILLS_TEMPLATE}/${skill_name}" ]]; then
      rm -rf "${SKILLS_DIR}/${skill_name}"
      cp -a "${SKILLS_TEMPLATE}/${skill_name}" "${SKILLS_DIR}/${skill_name}"
    fi
  done
  log "installed Pi skills from ${SKILLS_TEMPLATE}"
elif [[ ! -d "${SKILLS_DIR}/cloud-computer-overview" ]]; then
  log "WARN: Pi skills template missing at ${SKILLS_TEMPLATE}"
fi

if [[ ! -f "${CA_CERT_FILE}" && -f /root/.pi/agent/certs/lenovo-modelfactory-ca.pem ]]; then
  cp /root/.pi/agent/certs/lenovo-modelfactory-ca.pem "${CA_CERT_FILE}"
fi
if [[ -f "${CA_CERT_FILE}" ]]; then
  chmod 644 "${CA_CERT_FILE}" || true
fi

umask 077
cat > "${MODEL_FACTORY_ENV_FILE}" <<EOF
LENOVO_DEEPSEEK_V4_FLASH_API_KEY=${API_KEY}
EOF
chmod 600 "${MODEL_FACTORY_ENV_FILE}"

export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-${CA_CERT_FILE}}"

# Pin intranet DNS when /etc/hosts is writable (also re-applied at container start).
if [[ -n "${LENOVO_MODELFACTORY_HOST}" && -n "${LENOVO_MODELFACTORY_IP}" && -w /etc/hosts ]]; then
  tmp="$(mktemp)"
  awk -v h="${LENOVO_MODELFACTORY_HOST}" -v ip="${LENOVO_MODELFACTORY_IP}" '
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
  log "dns ${LENOVO_MODELFACTORY_HOST} -> ${LENOVO_MODELFACTORY_IP}"
fi

PI_MODELS_FILE="${MODELS_FILE}" \
PI_SETTINGS_FILE="${SETTINGS_FILE}" \
PI_MODELFACTORY_TEMPLATE="${PI_MODELFACTORY_TEMPLATE}" \
LENOVO_DEEPSEEK_PROVIDER="${LENOVO_DEEPSEEK_PROVIDER}" \
LENOVO_DEEPSEEK_MODEL="${LENOVO_DEEPSEEK_MODEL}" \
LENOVO_DEEPSEEK_BASE_URL="${LENOVO_DEEPSEEK_BASE_URL}" \
LENOVO_DEEPSEEK_MODEL_NAME="${LENOVO_DEEPSEEK_MODEL_NAME}" \
LENOVO_DEEPSEEK_V4_FLASH_API_KEY="${API_KEY}" \
node <<'NODE'
const fs = require("node:fs");

function readJson(path) {
  try {
    return fs.existsSync(path) ? JSON.parse(fs.readFileSync(path, "utf8")) : {};
  } catch {
    return {};
  }
}

const modelsPath = process.env.PI_MODELS_FILE;
const settingsPath = process.env.PI_SETTINGS_FILE;
const provider = String(process.env.LENOVO_DEEPSEEK_PROVIDER || "openai").trim();
const modelId = String(process.env.LENOVO_DEEPSEEK_MODEL || "DeepSeek").trim();
const apiKey = String(process.env.LENOVO_DEEPSEEK_V4_FLASH_API_KEY || "").trim();
const templatePath = String(process.env.PI_MODELFACTORY_TEMPLATE || "").trim();

const models = readJson(modelsPath);
const providers = models.providers && typeof models.providers === "object" ? { ...models.providers } : {};

const template = templatePath && fs.existsSync(templatePath) ? readJson(templatePath) : {};
providers[provider] = {
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

const next = { ...models, providers };
fs.writeFileSync(modelsPath, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
try { fs.chmodSync(modelsPath, 0o600); } catch {}

const settings = readJson(settingsPath);
const packages = Array.isArray(settings.packages) ? settings.packages : undefined;
fs.writeFileSync(settingsPath, `${JSON.stringify({
  ...settings,
  ...(packages ? { packages } : {}),
  defaultProvider: provider,
  defaultModel: modelId,
  defaultThinkingLevel: settings.defaultThinkingLevel ?? "high",
  theme: settings.theme ?? "dark",
}, null, 2)}\n`, { mode: 0o600 });
try { fs.chmodSync(settingsPath, 0o600); } catch {}

console.log(`[bake-pi-deepseek] defaultProvider=${provider} defaultModel=${modelId}`);
NODE

if [[ -d /etc/profile.d && -w /etc/profile.d ]]; then
  printf '%s\n' \
    "export NODE_EXTRA_CA_CERTS=\"\${NODE_EXTRA_CA_CERTS:-${CA_CERT_FILE}}\"" \
    > /etc/profile.d/lenovo-modelfactory-ca.sh \
    || log "WARN: could not write /etc/profile.d/lenovo-modelfactory-ca.sh"
  chmod 644 /etc/profile.d/lenovo-modelfactory-ca.sh 2>/dev/null || true
fi

log "baked DeepSeek into ${MODELS_FILE} and ${SETTINGS_FILE}"
