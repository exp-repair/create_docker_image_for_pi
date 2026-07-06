#!/usr/bin/env bash
# Create a Cube sandbox, then inject Pi/Multica runtime parameters and start daemon.
set -euo pipefail
cd "$(dirname "$0")/.."

CUBE_API_URL="${CUBE_API_URL:-http://127.0.0.1:3000}"
CUBE_PROXY_HTTP="${CUBE_PROXY_HTTP:-http://127.0.0.1}"
CUBE_TEMPLATE_ID="${CUBE_TEMPLATE_ID:-tpl-8fb171417c584db8bd5e0a86}"
CUBE_SANDBOX_TIMEOUT="${CUBE_SANDBOX_TIMEOUT:-3600}"
PI_CONFIG="${PI_CONFIG:-config/pi.env}"

if [[ -f "${PI_CONFIG}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${PI_CONFIG}"
  set +a
fi

required=(TEAM_API_KEY TEAM_BASE_URL TEAM_MODEL MULTICA_SERVER_URL MULTICA_APP_URL MULTICA_WORKSPACE_ID MULTICA_TOKEN)
missing=()
for key in "${required[@]}"; do
  [[ -n "${!key:-}" ]] || missing+=("${key}")
done
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
    "TEAM_API_KEY": os.environ["TEAM_API_KEY"],
    "TEAM_BASE_URL": os.environ["TEAM_BASE_URL"],
    "TEAM_MODEL": os.environ["TEAM_MODEL"],
    "MULTICA_SERVER_URL": os.environ["MULTICA_SERVER_URL"],
    "MULTICA_APP_URL": os.environ["MULTICA_APP_URL"],
    "MULTICA_WORKSPACE_ID": os.environ["MULTICA_WORKSPACE_ID"],
    "MULTICA_TOKEN": os.environ["MULTICA_TOKEN"],
    "MULTICA_DAEMON_ENABLED": os.environ.get("MULTICA_DAEMON_ENABLED", "1"),
}
for optional_key in ("BRIDGE_USER_ID", "AREAL_BASE_URL", "AREAL_API", "AREAL_API_KEY", "MULTICA_PROFILE"):
    if os.environ.get(optional_key):
        runtime_env[optional_key] = os.environ[optional_key]
code = """
import json, os, subprocess
runtime_env = json.loads(%r)
env = os.environ.copy()
env.update(runtime_env)
env["PATH"] = "/home/user/.npm-global/bin:/home/user/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
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
