# Cube sandbox slim image

Slim Docker image for Cube sandboxes that need db-bridge-routed LLM calls,
Multica daemon, Pi, Chromium/Playwright, Xvfb, VNC/noVNC, and the basic Cube
code-interpreter API.

## What this image provides

| Contract | Value |
| --- | --- |
| Base | `cube-sandbox-cn.tencentcloudcr.com/cube-sandbox/sandbox-code` |
| Workspace | `/workspace`, `/workspace/uploads`, `/workspace/browser-shots` |
| Code API | `:49999` from the lightweight Cube code interpreter |
| envd | `:49983` from the base image |
| Display | `DISPLAY=:0`, Xvfb desktop |
| Browser | System `/usr/bin/chromium`, CDP `:9223` |
| Live view | VNC `:5901`, noVNC `:6080` |
| Pi | `/usr/local/bin/pi` plus `@lebronj/pi-suite` |
| Multica | `/usr/local/bin/multica` daemon runtime helpers |

The image intentionally does **not** run or bundle the db_bridge Python service.
The bridge stub/executor should keep running on the host or service machines.
Inside the sandbox, Pi is configured to call the host bridge stub through the
`areal` provider using `AREAL_BASE_URL` and `BRIDGE_USER_ID`.

All account-scoped tools and configs live under root (`/root/.npm-global`,
`/root/.pi`, `/root/.multica`). The inherited non-root `user` account is removed
from the final image to avoid split runtime state.

## Build locally

```bash
./scripts/build.sh
```

Useful build overrides:

```bash
# Reuse a previously downloaded Multica binary.
MULTICA_SKIP_DOWNLOAD=1 ./scripts/build.sh

# Use an existing local Multica binary.
MULTICA_LOCAL_BIN=/usr/local/bin/multica ./scripts/build.sh

# Change image tag or base image.
TAG=cube-leagent-template:slim \
SANDBOX_IMAGE=cube-sandbox-cn.tencentcloudcr.com/cube-sandbox/sandbox-code@sha256:b551b169de85c0216cce9453a8e22059ca47fd3dceced75e918cf1c8de60464b \
./scripts/build.sh
```

Pi and Multica credentials are not baked into the image. Pass them when the
container or Cube sandbox starts.

## Run locally

```bash
cp config/pi.env.example config/pi.env
# edit config/pi.env and fill TEAM_* plus MULTICA_* runtime values
./scripts/run.sh
./scripts/diagnose.sh
```

For db-bridge, point Pi at the host bridge stub. The current multica-side stub
serves `/chat/completions`, so the default base URL has no `/v1` suffix:

```bash
AREAL_BASE_URL=http://10.110.158.143:9100
BRIDGE_USER_ID=<same user id used by db_bridge_stub/executor>
```

Inside the container, useful checks are:

```bash
curl -sf http://127.0.0.1:49999/health
curl -sf http://127.0.0.1:6080/
command -v chromium pi multica rg fd
python3 - <<'PY'
from playwright.sync_api import sync_playwright
print('playwright ok')
PY
```

## Publish to Cube

```bash
./scripts/create-cube-template.sh
```

The template creation script exposes Pi web `6079`, noVNC `6080`, and Chromium
CDP `9223`, then probes the Code API on `49999/health`.

If Cube sandboxes must reach the host db_bridge stubs on `:9100` / `:9101` /
`:9102`, keep the host bridge using `network_mode: host`, include the host LAN
IP in `ALLOW_OUT_CIDRS`, and apply the db_bridge tap/hairpin rules on the Cube
node when needed:

```bash
cd /home/jian40/multica/db_bridge
sudo scripts/cube-tap-tproxy-init.sh up
# optional override:
# CUBE_TPROXY_BRIDGE_PORTS="9100 9101 9102" sudo scripts/cube-tap-tproxy-init.sh up
```

## Runtime scripts

- `scripts/cube-start.sh` starts VNC/noVNC/Pi web helpers, optionally starts
  Multica when `MULTICA_AUTOSTART=1`, then execs the base lightweight Code API.
- `scripts/configure-pi-runtime.sh` writes Pi `models.json` and `settings.json`,
  including the `areal` db-bridge provider.
- `scripts/start-multica-runtime.sh` dynamically configures Pi/Multica inside an
  already-created sandbox and starts the Multica daemon in the background.
- `scripts/create-runtime-sandbox.sh` creates a Cube sandbox, injects runtime
  env, and invokes `start-multica-runtime.sh` through the Cube `/execute` API.
