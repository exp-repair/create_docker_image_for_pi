# scripts

Helpers for building the slim Cube sandbox image, running it locally, creating a
Cube template/sandbox, and configuring Pi + Cursor Agent + Multica at runtime.

## Recommended flow

1. `build.sh` builds `cube-leagent-template:local` from the lightweight Cube base.
2. `run.sh` starts a local debug container with Pi web, noVNC/VNC, and Code API ports.
   For the test/alpha daemon image, use `build-test.sh` / `run-test.sh` instead
   (`cube-leagent-template-test:local`).
3. `diagnose.sh` checks browser, Pi, Cursor Agent, Multica, and Cube API health.
4. `create-cube-template.sh` registers the local image as a Cube sandbox template.
5. `create-runtime-sandbox.sh` creates a sandbox, injects runtime secrets/config,
   and starts the Multica daemon.

## Scripts

| Script | Purpose |
| --- | --- |
| `build.sh` | Downloads or reuses the Multica binary from `https://cdn.leagent.me/computer` via `metainfo.json` (same feed as `install.sh`), then builds the image. Supports `MULTICA_VERSION=latest|test|vX.Y.Z`, `APT_MIRROR` / `APT_SECURITY_MIRROR` (default Aliyun Debian mirrors), `TAG`, `SANDBOX_IMAGE`, `NODE_MAJOR`, `INSTALL_PI`, `INSTALL_CURSOR`, `PI_SUITE_VERSION`, `NPM_REGISTRY`, `MULTICA_SKIP_DOWNLOAD`, `MULTICA_FORCE_DOWNLOAD`, `MULTICA_LOCAL_BIN`, `MULTICA_RELEASE_MANIFEST_BASE_URL`, and standard proxy build args. |
| `build-test.sh` | Independent test/alpha image build. Default tag `cube-leagent-template-test:local`, default `MULTICA_VERSION=test` (latest alpha, same as `install.sh --version v0.4.24-alpha.79`). Caches the binary under `multica/bin-test/` so `build.sh` is not affected. |
| `run.sh` | Runs the image locally, maps `6079`, `6080`, `5901`, `49983`, `49999`, and passes `TEAM_*`, `AREAL_*`, `BRIDGE_USER_ID`, `CURSOR_API_KEY`, `MULTICA_*`, and optional sandbox proxy env values. Uses `DOCKER_BIN` when set. |
| `run-test.sh` | Independent runner for the test image. Default container name suffix `-cube-leagent-test` and host ports `27079` / `27080` / `26901` / `25983` / `25999`. |
| `watch-test-daemon.sh` | Every 3 hours (cron) fetches `metainfo.json` `environments.test.tag` and rebuilds `cube-leagent-template-test:local` only when that alpha version changes. Logs to `logs/watch-test-daemon.log`. |
| `diagnose.sh` | Prints container state, listening ports, important binaries, Pi/Cursor/Multica versions, and host HTTP checks. Uses `DOCKER_BIN` when set. |
| `create-cube-template.sh` | Converts the image into a Cube template, exposing `6079`, `6080`, and `9223`, probing `49999/health`, and writing `.cube-template.env`. |
| `create-runtime-sandbox.sh` | Creates a Cube sandbox and invokes `start-multica-runtime.sh` through `/execute` to configure Pi/Cursor/Multica after creation. |
| `cube-start.sh` | Main image entrypoint. Starts VNC/noVNC/Pi web helpers, optionally starts Multica when `MULTICA_AUTOSTART=1`, then execs `/usr/local/bin/start-lightweight-code-interpreter.sh`. |
| `cont-init-browser.sh` | Starts `/entrypoint-vnc.sh` and `/entrypoint-pi-web.sh` under root. |
| `entrypoint-vnc.sh` | Starts Xvfb, openbox, Chromium with CDP `:9223`, x11vnc, and noVNC. |
| `entrypoint-pi-web.sh` | Starts the Pi web bridge backed by `pi --mode rpc`, including WebTTY at `/term`. |
| `configure-pi-runtime.sh` | Writes Pi `models.json` / `settings.json`, including areal and optional Lenovo ModelFactory DeepSeek. |
| `configure-cursor-runtime.sh` | Resolves `cursor-agent`, writes `/root/.cursor/runtime.env` from `CURSOR_API_KEY` / `MULTICA_CURSOR_*`. |
| `configure-multica-runtime.sh` | Writes Multica CLI/daemon config from runtime `MULTICA_*` values. |
| `entrypoint-multica-daemon.sh` | Configures Pi/Cursor/Multica and runs `multica daemon supervise` (Machine Upgrade handoff-safe), with an outer bash restart loop. |
| `start-multica-runtime.sh` | Reconfigures Pi/Cursor/Multica inside a running sandbox and starts the supervised daemon in the background. |

## Key environment variables

| Variable | Meaning |
| --- | --- |
| `TEAM_API_KEY`, `TEAM_BASE_URL`, `TEAM_MODEL`, `TEAM_PROVIDER` | Optional Pi TEAM provider credentials/model (kept alongside DeepSeek when set). |
| `LENOVO_DEEPSEEK_V4_FLASH_API_KEY` | **Baked into the image at build time** (from `config/pi.env`). Multica sandboxes get DeepSeek without runtime injection. Do not push the image publicly. |
| `LENOVO_DEEPSEEK_AS_DEFAULT` | `1` (default) makes DeepSeek the Pi `defaultProvider`/`defaultModel`. |
| `LENOVO_MODELFACTORY_HOST`, `LENOVO_MODELFACTORY_IP` | Pins `modelfactory.lenovo.com` in `/etc/hosts` (and `docker run --add-host`) when intranet DNS is missing. |
| `AREAL_BASE_URL` | db-bridge AReaL provider base URL. Default is `http://10.110.158.143:9100` for the current stub. |
| `AREAL_API`, `AREAL_API_KEY` | Pi provider API type/key for AReaL bridge calls. |
| `BRIDGE_USER_ID` | Sent as `X-Bridge-User-Id` on db-bridge calls. Must match bridge stub/executor scope. |
| `CURSOR_API_KEY` | Cursor Agent auth for Multica's Cursor runtime. Injected at runtime only. |
| `MULTICA_CURSOR_PATH` | Optional override path to `cursor-agent`. |
| `MULTICA_CURSOR_MODEL` | Optional Multica default model for Cursor Agent. |
| `INSTALL_CURSOR` | Build-time flag (`1`/`0`) to install Cursor Agent CLI into the image. |
| `MULTICA_SERVER_URL`, `MULTICA_APP_URL`, `MULTICA_WORKSPACE_ID`, `MULTICA_TOKEN` | Required to configure Multica daemon. Defaults for URLs are `https://leagent.me` (headless stand-in for `multica setup self-host`). |
| `MULTICA_ENVIRONMENT` | `test` writes `environment=test` / `release_channel=alpha` so Machine Upgrade follows preview packages. Production runs omit this (or set `production`). Test origin cannot be `leagent.me`; `run-test.sh` defaults to `https://82.157.184.89`. |
| `MULTICA_PROFILE` | Optional profile name under `~/.multica/profiles/<name>`. |
| `MULTICA_DAEMON_ENABLED` | `1` to run the daemon, `0` to keep it disabled. |
| `MULTICA_DAEMON_MODE` | `supervise` (default, recommended) runs `multica daemon supervise` so Machine Upgrade handoffs auto-restart onto the staged CLI; `foreground` uses `daemon start --foreground` for debug. |
| `MULTICA_DAEMON_SUPERVISE` | `1` (default) outer bash loop restarts the Multica supervise/foreground process if it exits; `0` for a one-shot run. |
| `MULTICA_DAEMON_RESTART_DELAY_SEC` | Seconds to wait before the outer loop restarts after an exit. Default `2`. |
| `MULTICA_AUTOSTART` | `1` to start Multica during container entrypoint; otherwise use `start-multica-runtime.sh`. |
| `CUBE_TEMPLATE_ID`, `CUBE_API_URL`, `CUBE_PROXY_HTTP` | Cube runtime sandbox creation settings. |
| `ENABLE_SANDBOX_HOST_PROXY`, `HOST_PROXY_PORT`, `SANDBOX_PROXY_URL`, `SANDBOX_NO_PROXY` | Optional host-proxy settings for sandbox egress; use the host sing-box mixed proxy on `:7893`. |

## Notes

- Secrets are runtime-only; do not bake `TEAM_*`, `CURSOR_API_KEY`, `MULTICA_TOKEN`,
  Supabase keys, or bridge credentials into Docker layers.
- Multica daemon auto-detects `cursor-agent` on `PATH` the same way it detects `pi`.
  After daemon start, create/select a Multica agent that uses the Cursor runtime.
- The sandbox image is a db-bridge client. The db_bridge stub/executor Python
  service stays in `/home/jian40/multica/db_bridge` and runs separately.
- The current `run_stub --side multica` serves `/chat/completions`; therefore the
  Pi `AREAL_BASE_URL` should not include `/v1` unless you intentionally route to
  `multica_server.py` instead.
