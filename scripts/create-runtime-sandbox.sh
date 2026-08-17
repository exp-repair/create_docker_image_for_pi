#!/usr/bin/env bash
# Create a Cube sandbox, then inject Pi/Cursor/Multica runtime parameters and start daemon.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .cube-template.env ]]; then
  # shellcheck disable=SC1091
  source .cube-template.env
fi

CUBE_API_URL="${CUBE_API_URL:-http://127.0.0.1:3000}"
CUBE_PROXY_HTTP="${CUBE_PROXY_HTTP:-http://127.0.0.1}"
CUBE_TEMPLATE_ID="${CUBE_TEMPLATE_ID:-tpl-17d5b530e726456691304136}"
CUBE_SANDBOX_TIMEOUT="${CUBE_SANDBOX_TIMEOUT:-3600}"
PI_CONFIG="${PI_CONFIG:-config/pi.env}"
HOST_IP="${HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
HOST_PROXY_PORT="${HOST_PROXY_PORT:-7893}"
ENABLE_SANDBOX_HOST_PROXY="${ENABLE_SANDBOX_HOST_PROXY:-0}"
SANDBOX_PROXY_URL="${SANDBOX_PROXY_URL:-}"
SANDBOX_NO_PROXY="${SANDBOX_NO_PROXY:-localhost,127.0.0.1,::1,${HOST_IP},10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local}"

if [[ -f "${PI_CONFIG}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${PI_CONFIG}"
  set +a
fi

if [[ -z "${SANDBOX_PROXY_URL}" && "${ENABLE_SANDBOX_HOST_PROXY}" == "1" ]]; then
  SANDBOX_PROXY_URL="http://${HOST_IP}:${HOST_PROXY_PORT}"
fi
LENOVO_MODELFACTORY_HOST="${LENOVO_MODELFACTORY_HOST:-modelfactory.lenovo.com}"
LENOVO_MODELFACTORY_IP="${LENOVO_MODELFACTORY_IP:-10.110.158.101}"
case ",${SANDBOX_NO_PROXY}," in
  *",${LENOVO_MODELFACTORY_HOST},"*) ;;
  *) SANDBOX_NO_PROXY="${SANDBOX_NO_PROXY},${LENOVO_MODELFACTORY_HOST}" ;;
esac
case ",${SANDBOX_NO_PROXY}," in
  *",${LENOVO_MODELFACTORY_IP},"*) ;;
  *) SANDBOX_NO_PROXY="${SANDBOX_NO_PROXY},${LENOVO_MODELFACTORY_IP}" ;;
esac
export SANDBOX_PROXY_URL SANDBOX_NO_PROXY LENOVO_MODELFACTORY_HOST LENOVO_MODELFACTORY_IP

required=(MULTICA_SERVER_URL MULTICA_APP_URL MULTICA_WORKSPACE_ID MULTICA_TOKEN)
missing=()
for key in "${required[@]}"; do
  [[ -n "${!key:-}" ]] || missing+=("${key}")
done
if [[ -z "${TEAM_API_KEY:-}" && -z "${LENOVO_DEEPSEEK_V4_FLASH_API_KEY:-}" ]]; then
  missing+=("TEAM_API_KEY|LENOVO_DEEPSEEK_V4_FLASH_API_KEY")
fi
if [[ -n "${TEAM_API_KEY:-}" ]]; then
  for key in TEAM_BASE_URL TEAM_MODEL; do
    [[ -n "${!key:-}" ]] || missing+=("${key}")
  done
fi
if (( ${#missing[@]} > 0 )); then
  echo "[create-runtime-sandbox] missing required env: ${missing[*]}" >&2
  exit 1
fi

SANDBOX_OUTPUT=$(curl -sS --max-time 90 \
  -X POST "${CUBE_API_URL}/sandboxes" \
  -H 'Content-Type: application/json' \
  -d "{\"templateID\":\"${CUBE_TEMPLATE_ID}\",\"timeout\":${CUBE_SANDBOX_TIMEOUT}}")

CUBE_SANDBOX_ID=$(SANDBOX_OUTPUT="${SANDBOX_OUTPUT}" python3 - <<'PY'
import json
import os
import sys

raw = os.environ.get("SANDBOX_OUTPUT", "")
try:
    data = json.loads(raw)
except Exception as exc:
    print(f"[create-runtime-sandbox] invalid create response JSON: {exc}", file=sys.stderr)
    print(raw, file=sys.stderr)
    raise SystemExit(1)

sandbox_id = data.get("sandboxID")
if not sandbox_id:
    print("[create-runtime-sandbox] sandbox create failed; response:", file=sys.stderr)
    print(json.dumps(data, ensure_ascii=False, indent=2), file=sys.stderr)
    raise SystemExit(1)
print(sandbox_id)
PY
)
echo "[create-runtime-sandbox] sandbox=${CUBE_SANDBOX_ID}"

python3 - <<'PY' > /tmp/cube-start-multica-runtime.json
import json, os
runtime_env = {
    "MULTICA_SERVER_URL": os.environ["MULTICA_SERVER_URL"],
    "MULTICA_APP_URL": os.environ["MULTICA_APP_URL"],
    "MULTICA_WORKSPACE_ID": os.environ["MULTICA_WORKSPACE_ID"],
    "MULTICA_TOKEN": os.environ["MULTICA_TOKEN"],
    "MULTICA_DAEMON_ENABLED": os.environ.get("MULTICA_DAEMON_ENABLED", "1"),
    "NODE_EXTRA_CA_CERTS": os.environ.get(
        "NODE_EXTRA_CA_CERTS",
        "/root/.pi/agent/certs/lenovo-modelfactory-ca.pem",
    ),
    "LENOVO_DEEPSEEK_AS_DEFAULT": os.environ.get("LENOVO_DEEPSEEK_AS_DEFAULT", "1"),
    "LENOVO_DEEPSEEK_PROVIDER": os.environ.get(
        "LENOVO_DEEPSEEK_PROVIDER", "lenovo-deepseek-v4-flash"
    ),
    "LENOVO_DEEPSEEK_MODEL": os.environ.get(
        "LENOVO_DEEPSEEK_MODEL", "DeepSeek-V4-Flash-0731"
    ),
    "LENOVO_DEEPSEEK_BASE_URL": os.environ.get(
        "LENOVO_DEEPSEEK_BASE_URL",
        "https://modelfactory.lenovo.com/service-large-600-1777255649450/llm/v1",
    ),
    "LENOVO_MODELFACTORY_HOST": os.environ.get(
        "LENOVO_MODELFACTORY_HOST", "modelfactory.lenovo.com"
    ),
    "LENOVO_MODELFACTORY_IP": os.environ.get(
        "LENOVO_MODELFACTORY_IP", "10.110.158.101"
    ),
}
for required_team in ("TEAM_API_KEY", "TEAM_BASE_URL", "TEAM_MODEL"):
    if os.environ.get(required_team):
        runtime_env[required_team] = os.environ[required_team]
if os.environ.get("TEAM_API"):
    runtime_env["TEAM_API"] = os.environ["TEAM_API"]
else:
    runtime_env["TEAM_API"] = "openai-responses"
proxy_url = os.environ.get("SANDBOX_PROXY_URL", "")
if proxy_url:
    runtime_env.update({
        "HTTP_PROXY": proxy_url,
        "HTTPS_PROXY": proxy_url,
        "ALL_PROXY": proxy_url,
        "http_proxy": proxy_url,
        "https_proxy": proxy_url,
        "all_proxy": proxy_url,
        "NO_PROXY": os.environ.get("SANDBOX_NO_PROXY", "localhost,127.0.0.1,::1"),
        "no_proxy": os.environ.get("SANDBOX_NO_PROXY", "localhost,127.0.0.1,::1"),
    })
for optional_key in (
    "TEAM_PROVIDER",
    "TEAM_PI_CONFIG",
    "BRIDGE_USER_ID",
    "AREAL_BASE_URL",
    "AREAL_API",
    "AREAL_API_KEY",
    "MULTICA_PROFILE",
    "MULTICA_ENVIRONMENT",
    "CURSOR_API_KEY",
    "MULTICA_CURSOR_PATH",
    "MULTICA_CURSOR_MODEL",
    "MULTICA_DAEMON_MODE",
    "MULTICA_DAEMON_SUPERVISE",
    "LENOVO_DEEPSEEK_V4_FLASH_API_KEY",
    "LENOVO_DEEPSEEK_MODEL_NAME",
):
    if os.environ.get(optional_key):
        runtime_env[optional_key] = os.environ[optional_key]
code = """
import json, os, subprocess
runtime_env = json.loads(%r)
env = os.environ.copy()
env.update(runtime_env)
env["HOME"] = "/root"
env["PATH"] = "/root/.local/bin:/root/.npm-global/bin:/root/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
proc = subprocess.run(["bash", "-lc", "/usr/local/bin/start-multica-runtime.sh"], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60, env=env)
print(proc.stdout)
if proc.returncode != 0:
    raise SystemExit(proc.returncode)
""" % json.dumps(runtime_env)
print(json.dumps({"code": code, "language": "python"}))
PY

curl -sS --max-time 90 \
  -H "Host: 49999-${CUBE_SANDBOX_ID}.cube.app" \
  -H 'Content-Type: application/json' \
  --data @/tmp/cube-start-multica-runtime.json \
  "${CUBE_PROXY_HTTP}/execute"

echo ""
echo "CUBE_SANDBOX_ID=${CUBE_SANDBOX_ID}"
echo "CUBE_TEMPLATE_ID=${CUBE_TEMPLATE_ID}"
