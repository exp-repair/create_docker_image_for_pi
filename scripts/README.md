# scripts

Helpers for building the slim Cube sandbox image, running it locally, creating a
Cube template/sandbox, and configuring Pi + Cursor Agent + Multica at runtime.

## Recommended flow

1. `build.sh` builds `cube-leagent-template:local` from the lightweight Cube base.
2. `run.sh` starts a local debug container with Pi web, noVNC/VNC, and Code API ports.
3. `diagnose.sh` checks browser, Pi, Cursor Agent, Multica, and Cube API health.
4. `create-cube-template.sh` registers the local image as a Cube sandbox template.
5. `create-runtime-sandbox.sh` creates a sandbox, injects runtime secrets/config,
   and starts the Multica daemon.

## Scripts

| Script | Purpose |
| --- | --- |
| `build.sh` | Downloads or reuses the Multica binary from `https://cdn.leagent.me/computer` (same feed as `install.sh`), then builds the image. Supports `TAG`, `SANDBOX_IMAGE`, `NODE_MAJOR`, `INSTALL_PI`, `INSTALL_CURSOR`, `PI_SUITE_VERSION`, `NPM_REGISTRY`, `MULTICA_SKIP_DOWNLOAD`, `MULTICA_FORCE_DOWNLOAD`, `MULTICA_LOCAL_BIN`, `MULTICA_RELEASE_MANIFEST_BASE_URL`, and standard proxy build args. |
| `run.sh` | Runs the image locally, maps `6079`, `6080`, `5901`, `49983`, `49999`, and passes `TEAM_*`, `AREAL_*`, `BRIDGE_USER_ID`, `CURSOR_API_KEY`, `MULTICA_*`, and optional sandbox proxy env values. Uses `DOCKER_BIN` when set. |
| `diagnose.sh` | Prints container state, listening ports, important binaries, Pi/Cursor/Multica versions, and host HTTP checks. Uses `DOCKER_BIN` when set. |
| `create-cube-template.sh` | Converts the image into a Cube template, exposing `6079`, `6080`, and `9223`, probing `49999/health`, and writing `.cube-template.env`. |
| `create-runtime-sandbox.sh` | Creates a Cube sandbox and invokes `start-multica-runtime.sh` through `/execute` to configure Pi/Cursor/Multica after creation. |
| `cube-start.sh` | Main image entrypoint. Starts VNC/noVNC/Pi web helpers, optionally starts Multica when `MULTICA_AUTOSTART=1`, then execs `/usr/local/bin/start-lightweight-code-interpreter.sh`. |
| `cont-init-browser.sh` | Starts `/entrypoint-vnc.sh` and `/entrypoint-pi-web.sh` under root. |
| `entrypoint-vnc.sh` | Starts Xvfb, openbox, Chromium with CDP `:9223`, x11vnc, and noVNC. |
| `entrypoint-pi-web.sh` | Starts the Pi web bridge backed by `pi --mode rpc`, including WebTTY at `/term`. |
| `configure-pi-runtime.sh` | Writes Pi `models.json` / `settings.json`, including the `areal` provider for db-bridge. |
| `configure-cursor-runtime.sh` | Resolves `cursor-agent`, writes `/root/.cursor/runtime.env` from `CURSOR_API_KEY` / `MULTICA_CURSOR_*`. |
| `configure-multica-runtime.sh` | Writes Multica CLI/daemon config from runtime `MULTICA_*` values. |
| `entrypoint-multica-daemon.sh` | Configures Pi/Cursor/Multica and runs `multica daemon start --foreground`, restarting it by default if it exits. |
| `start-multica-runtime.sh` | Reconfigures Pi/Cursor/Multica inside a running sandbox and starts the supervised daemon in the background. |

## Key environment variables

| Variable | Meaning |
| --- | --- |
| `TEAM_API_KEY`, `TEAM_BASE_URL`, `TEAM_MODEL`, `TEAM_PROVIDER` | Pi default provider credentials/model. |
| `AREAL_BASE_URL` | db-bridge AReaL provider base URL. Default is `http://10.110.158.143:9100` for the current stub. |
| `AREAL_API`, `AREAL_API_KEY` | Pi provider API type/key for AReaL bridge calls. |
| `BRIDGE_USER_ID` | Sent as `X-Bridge-User-Id` on db-bridge calls. Must match bridge stub/executor scope. |
| `CURSOR_API_KEY` | Cursor Agent auth for Multica's Cursor runtime. Injected at runtime only. |
| `MULTICA_CURSOR_PATH` | Optional override path to `cursor-agent`. |
| `MULTICA_CURSOR_MODEL` | Optional Multica default model for Cursor Agent. |
| `INSTALL_CURSOR` | Build-time flag (`1`/`0`) to install Cursor Agent CLI into the image. |
| `MULTICA_SERVER_URL`, `MULTICA_APP_URL`, `MULTICA_WORKSPACE_ID`, `MULTICA_TOKEN` | Required to configure Multica daemon. Defaults for URLs are `https://leagent.me` (headless stand-in for `multica setup self-host`). |
| `MULTICA_PROFILE` | Optional profile name under `~/.multica/profiles/<name>`. |
| `MULTICA_DAEMON_ENABLED` | `1` to run the daemon, `0` to keep it disabled. |
| `MULTICA_DAEMON_SUPERVISE` | `1` (default) to restart `daemon start --foreground` when it exits; `0` for a one-shot run. |
| `MULTICA_DAEMON_RESTART_DELAY_SEC` | Seconds to wait before restarting after an exit. Default `2`. |
| `MULTICA_DAEMON_AUTO_UPDATE` | Image default `false`. Keep disabled: the bash restart loop is not Multica `install-service` supervision, so release auto-update can still stop the daemon after staging a new CLI. |
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
