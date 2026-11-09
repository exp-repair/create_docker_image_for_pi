# Cube sandbox slim image

Slim Docker image for Cube sandboxes that need db-bridge-routed LLM calls,
Multica daemon, Pi, Cursor Agent CLI, Chromium/Playwright, Xvfb, VNC/noVNC, and
the basic Cube code-interpreter API.

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
| Cursor Agent | `/usr/local/bin/cursor-agent` (Multica auto-detects this binary) |
| Multica | `/usr/local/bin/multica` daemon runtime helpers |

The image intentionally does **not** run or bundle the db_bridge Python service.
The bridge stub/executor should keep running on the host or service machines.
Inside the sandbox, Pi is configured to call the host bridge stub through the
`areal` provider using `AREAL_BASE_URL` and `BRIDGE_USER_ID`.

All account-scoped tools and configs live under root (`/root/.npm-global`,
`/root/.pi`, `/root/.cursor`, `/root/.multica`, `/root/.local`). The inherited
non-root `user` account is removed from the final image to avoid split runtime
state.

## Swarm computer (staging / production)

环境相关地址与镜像 tag 由配置文件驱动，不再写死 staging：

```bash
cp config/coforge.env.example config/coforge.env
# 编辑 COFORGE_ENV=staging 或 production
# 也可改 config/environments/<env>.env 里的 feed / cloud host / image tag

./scripts/build-swarm.sh
# 或一次性覆盖：
# COFORGE_ENV=production ./scripts/build-swarm.sh
```

| 配置 | 作用 |
| --- | --- |
| `config/coforge.env` | 选择 `COFORGE_ENV`，可覆盖单个字段（已 gitignore） |
| `config/environments/staging.env` | staging feed / cloud host / tag |
| `config/environments/production.env` | production feed / cloud host / tag |

`build-swarm.sh` 会按配置下载对应 feed 的 `linux-x64` Computer、校验 checksum，并用 `COFORGE_CLOUD_HOST` 检查二进制是否面向该环境。镜像内会写入 `COFORGE_RELEASE_FEED_URL`，供运行时 `activate-computer-release` 使用。入口仍是 `coforge-computer foreground`，不跑 `setup --workspace`。启动时会把用户安装的 `/opt`、home、`/workspace`、Python venv 迁到 `/root/.coforge` volume。Pi / DeepSeek / Lenovo CA 打进镜像；DeepSeek key 来自 `config/pi.env`，勿推公共仓库。staging 运维步骤见 CoForge 仓库 `docs/operations/cloud-swarm/staging-bring-up.md`。

## Build locally

```bash
./scripts/build.sh
```

Test/alpha daemon image (latest alpha from `metainfo.json` `environments.test`, currently the same feed as `install.sh --version v0.4.24-alpha.79`). Does not change the production build:

```bash
./scripts/build-test.sh
./scripts/run-test.sh
```

That image is tagged `cube-leagent-template-test:local` and uses different host ports so it can run next to the production container. The test container connects to the Tencent Cloud test origin (`https://82.157.184.89` by default), seeds `$HOME/.local/bin/multica` so Machine Upgrade can swap and restart, and keeps `daemon/computer supervise` running.

Useful build overrides:

```bash
# Reuse a previously downloaded Multica binary.
MULTICA_SKIP_DOWNLOAD=1 ./scripts/build.sh

# Use an existing local Multica binary.
MULTICA_LOCAL_BIN=/usr/local/bin/multica ./scripts/build.sh

# Skip Cursor Agent CLI install.
INSTALL_CURSOR=0 ./scripts/build.sh

# Change image tag or base image.
TAG=cube-leagent-template:slim \
SANDBOX_IMAGE=cube-sandbox-cn.tencentcloudcr.com/cube-sandbox/sandbox-code@sha256:b551b169de85c0216cce9453a8e22059ca47fd3dceced75e918cf1c8de60464b \
./scripts/build.sh
```

Pi, Cursor, and Multica credentials are not baked into the image. Pass them when
the container or Cube sandbox starts (`TEAM_*`, `CURSOR_API_KEY`, `MULTICA_*`).

## Run locally

```bash
cp config/pi.env.example config/pi.env
# edit config/pi.env and fill TEAM_* , CURSOR_API_KEY, plus MULTICA_* runtime values
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
command -v chromium pi cursor-agent multica rg fd coforge-cdp-endpoint
```

After Multica daemon starts with `CURSOR_API_KEY` injected, the Multica UI
Runtimes page should list a Cursor runtime alongside Pi.

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

Cursor Agent also needs egress to Cursor API hosts (for example `api2.cursor.sh`).
If sandboxes use an HTTP proxy and Cursor auth fails, ensure those hosts are in
`NO_PROXY` (configure-cursor-runtime.sh adds common Cursor API hosts automatically
when a proxy is present).

## Lenovo intranet

The image trusts Lenovo SHA2 root/sub CAs under `config/certs/`. At start,
`render-lenovo-proxy.sh` writes Chromium proxy policy from `SANDBOX_PROXY_URL` /
`LENOVO_PROXY` (or a probed host `:7893`). Users open intranet sites in Chromium
and sign in with their own username/password — never bake credentials into the image.

## Host proxy for sandbox egress

The host currently exposes a sing-box mixed proxy on `:7893`. To make a sandbox
use that proxy, inject proxy envs and make sure the template allows egress to the
host LAN IP. `create-cube-template.sh` defaults `ENABLE_SANDBOX_HOST_PROXY=1`.

For local Docker runs:

```bash
ENABLE_SANDBOX_HOST_PROXY=1 ./scripts/run.sh
# or explicitly:
# SANDBOX_PROXY_URL=http://host.docker.internal:7893 ./scripts/run.sh
```

For Cube templates, create a new template with proxy envs baked into the template
runtime environment:

```bash
HOST_IP=10.110.158.143 \
ENABLE_SANDBOX_HOST_PROXY=1 \
ALLOW_OUT_CIDRS="192.168.0.1/32 10.110.158.143/32" \
./scripts/create-cube-template.sh
```

Inside a sandbox, verify with:

```bash
env | grep -i proxy
curl -I https://github.com
curl -I https://www.google.com
```

## Runtime scripts

- `scripts/cube-start.sh` starts VNC/noVNC/Pi web helpers, optionally starts
  Multica when `MULTICA_AUTOSTART=1`, then execs the base lightweight Code API.
- `scripts/configure-pi-runtime.sh` writes Pi `models.json` and `settings.json`,
  including the `areal` db-bridge provider. When
  `LENOVO_DEEPSEEK_V4_FLASH_API_KEY` is set it also merges Lenovo ModelFactory
  DeepSeek, trusts the baked CA via `NODE_EXTRA_CA_CERTS`, pins
  `modelfactory.lenovo.com` DNS, and (by default) sets DeepSeek as the Pi default.
- `scripts/sync-pi-skills.sh` + `scripts/bind-pi-skills.sh`: seed image skills into
  `/workspace/skills`, then `mount --bind` that directory onto
  `/root/.pi/agent/skills` so new container-level skills persist automatically.
  The image sets `COFORGE_CLOUD_COMPUTER=1` so CoForge also persists per-Agent
  skills under `/workspace/agent-skills/<agentId>/` (gate off elsewhere → no
  behavior change). Verify with `scripts/test_sync_pi_skills.sh`.
- `scripts/configure-cursor-runtime.sh` resolves `cursor-agent`, writes
  `/root/.cursor/runtime.env` from `CURSOR_API_KEY` / `MULTICA_CURSOR_*`, and
  adjusts `NO_PROXY` for Cursor API hosts when a proxy is set.
- `scripts/start-multica-runtime.sh` dynamically configures Pi/Cursor/Multica
  inside an already-created sandbox and starts Multica under
  `daemon supervise` plus an outer restart loop
  (`entrypoint-multica-daemon.sh`, `MULTICA_DAEMON_MODE=supervise`).
  That path completes Machine Upgrade handoffs so the daemon comes back on
  the newly staged CLI without a manual restart.
- `scripts/create-runtime-sandbox.sh` creates a Cube sandbox, injects runtime
  env, and invokes `start-multica-runtime.sh` through the Cube `/execute` API.
