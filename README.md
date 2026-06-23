# Cube / E2B sandbox template (Leagent-aligned)

Docker overlay for Cube `sandbox-code` / `e2b-code-interpreter` images. Matches
Leagent's River (Daytona) sandbox contracts without changing backend code.

## What this image provides

| Contract | Value |
|----------|--------|
| Workspace | `/workspace`, `/workspace/uploads`, `/workspace/browser-shots` |
| Display | `DISPLAY=:0` (Xvfb) |
| Browser | System `/usr/bin/chromium`, CDP `127.0.0.1:9223` (Leagent bootstraps on demand) |
| Live view | VNC `:5901`, noVNC `:6080` (same probes as Daytona Computer Use) |
| E2B APIs | `:49983` envd, `:49999` code interpreter (from base image) |

Removed vs earlier template: resident `demo.js` / FastAPI `server.py`, duplicate
Playwright browser downloads, `tesseract`, `wkhtmltopdf`, redundant Chromium libs,
debug packages (`ping`, `dnsutils`, `lsof`, `tigervnc-tools`), duplicate fonts.

**Not installed here** (expected from `e2b-code-interpreter` base): `git`, `tmux`,
`bash`, `wget`, `python3`, Node, `sudo`, coreutils (`grep`/`sed`).

## Build locally

```bash
cd backend/core/sandbox/cube/docker_container
./scripts/build.sh
# optional: SANDBOX_IMAGE=... NOVNC_ARCHIVE_URL=... ./scripts/build.sh
```

## Run locally (smoke test)

```bash
./scripts/run.sh
./scripts/diagnose.sh
```

Inside the container:

```bash
ls -la /workspace /workspace/uploads
touch /workspace/uploads/test.txt
command -v chromium rg
DISPLAY=:0 xdpyinfo | head
```

After Leagent browser bootstrap (or manual):

```bash
curl -sf http://127.0.0.1:9223/json/version
```

## Publish to Cube

1. Build and push the image to your registry.
2. Register it as an E2B/Cube template (`tpl-...`).
3. Set `CUBE_TEMPLATE_ID` in `backend/.env` and `backend/core/infra/sandbox/provider/cube/.env`.
4. Restart workers and create a **new** sandbox (old sandboxes keep the old template).

## Relation to Daytona River

| | Daytona River | This template |
|--|---------------|---------------|
| Build | `backend/core/sandbox/create_daytona_snapshot.py` | `docker build` → Cube template |
| Base | `daytonaio/sandbox:0.6.0` | `e2b-code-interpreter` / `sandbox-code` |
| Dockerfile | `backend/core/sandbox/docker/Dockerfile` | this directory |

Python tools (`playwright`, `pypdf`, `python-pptx`) and document CLI packages mirror River.
Presentation export CLI (`river-export-slides`) is not bundled here; add it to this
directory if you need full slide/PDF parity on Cube.
