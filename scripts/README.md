# scripts

Helpers for building the slim Cube sandbox image, running it locally, creating a
Cube template/sandbox, and configuring Pi + Multica at runtime.

## Recommended flow

1. `build.sh` builds `cube-leagent-template:local` from the lightweight Cube base.
2. `run.sh` starts a local debug container with Pi web, noVNC/VNC, and Code API ports.
3. `diagnose.sh` checks browser, Pi, Multica, and Cube API health.
4. `create-cube-template.sh` registers the local image as a Cube sandbox template.
5. `create-runtime-sandbox.sh` creates a sandbox, injects runtime secrets/config,
   and starts the Multica daemon.

## Scripts

| Script | Purpose |
| --- | --- |
| `build.sh` | Downloads or reuses the Multica binary, then builds the image. Defaults to `cube-sandbox-cn.tencentcloudcr.com/cube-sandbox/sandbox-code@sha256:b551...`. Supports `TAG`, `SANDBOX_IMAGE`, `NODE_MAJOR`, `INSTALL_PI`, `PI_SUITE_VERSION`, `NPM_REGISTRY`, `MULTICA_SKIP_DOWNLOAD`, and `MULTICA_LOCAL_BIN`. |
| `run.sh` | Runs the image locally, maps `6079`, `6080`, `5901`, `49983`, `49999`, and passes `TEAM_*`, `AREAL_*`, `BRIDGE_USER_ID`, and `MULTICA_*` runtime env values. Uses `DOCKER_BIN` when set. |
| `diagnose.sh` | Prints container state, listening ports, important binaries, Pi/Multica versions, and host HTTP checks. Uses `DOCKER_BIN` when set. |
| `create-cube-template.sh` | Converts the image into a Cube template, exposing `6079`, `6080`, and `9223`, probing `49999/health`, and writing `.cube-template.env`. |
| `create-runtime-sandbox.sh` | Creates a Cube sandbox and invokes `start-multica-runtime.sh` through `/execute` to configure Pi/Multica after creation. |
| `cube-start.sh` | Main image entrypoint. Starts VNC/noVNC/Pi web helpers, optionally starts Multica when `MULTICA_AUTOSTART=1`, then execs `/usr/local/bin/start-lightweight-code-interpreter.sh`. |
| `cont-init-browser.sh` | Starts `/entrypoint-vnc.sh` and `/entrypoint-pi-web.sh` under root. |
| `entrypoint-vnc.sh` | Starts Xvfb, openbox, Chromium with CDP `:9223`, x11vnc, and noVNC. |
| `entrypoint-pi-web.sh` | Starts the Pi web bridge backed by `pi --mode rpc`. |
| `configure-pi-runtime.sh` | Writes Pi `models.json` / `settings.json`, including the `areal` provider for db-bridge. |
| `configure-multica-runtime.sh` | Writes Multica CLI/daemon config from runtime `MULTICA_*` values. |
| `entrypoint-multica-daemon.sh` | Configures Pi/Multica and runs `multica daemon start --foreground`. |
| `start-multica-runtime.sh` | Reconfigures Pi/Multica inside a running sandbox and starts the daemon in the background. |

## Key environment variables

| Variable | Meaning |
| --- | --- |
| `TEAM_API_KEY`, `TEAM_BASE_URL`, `TEAM_MODEL`, `TEAM_PROVIDER` | Pi default provider credentials/model. |
| `AREAL_BASE_URL` | db-bridge AReaL provider base URL. Default is `http://10.110.158.143:9100` for the current stub. |
| `AREAL_API`, `AREAL_API_KEY` | Pi provider API type/key for AReaL bridge calls. |
| `BRIDGE_USER_ID` | Sent as `X-Bridge-User-Id` on db-bridge calls. Must match bridge stub/executor scope. |
| `MULTICA_SERVER_URL`, `MULTICA_APP_URL`, `MULTICA_WORKSPACE_ID`, `MULTICA_TOKEN` | Required to configure Multica daemon. |
| `MULTICA_PROFILE` | Optional profile name under `~/.multica/profiles/<name>`. |
| `MULTICA_DAEMON_ENABLED` | `1` to run the daemon, `0` to keep it disabled. |
| `MULTICA_AUTOSTART` | `1` to start Multica during container entrypoint; otherwise use `start-multica-runtime.sh`. |
| `CUBE_TEMPLATE_ID`, `CUBE_API_URL`, `CUBE_PROXY_HTTP` | Cube runtime sandbox creation settings. |

## Notes

- Secrets are runtime-only; do not bake `TEAM_*`, `MULTICA_TOKEN`, Supabase keys,
  or bridge credentials into Docker layers.
- The sandbox image is a db-bridge client. The db_bridge stub/executor Python
  service stays in `/home/jian40/multica/db_bridge` and runs separately.
- The current `run_stub --side multica` serves `/chat/completions`; therefore the
  Pi `AREAL_BASE_URL` should not include `/v1` unless you intentionally route to
  `multica_server.py` instead.
