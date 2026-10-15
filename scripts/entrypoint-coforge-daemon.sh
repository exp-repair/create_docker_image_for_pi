#!/usr/bin/env bash
# Start the CoForge Computer supervisor, then attach this container to one Workspace
# when a login credential is already present. The bundled binary is built for the
# local CoForge at http://localhost:8789, so the container must share the host network.
set -euo pipefail

export HOME="${HOME:-/root}"
export PATH="/usr/local/bin:${PATH}"

BIN="${COFORGE_COMPUTER_BIN:-/usr/local/bin/coforge-computer}"
SOCKET="${HOME}/.coforge/daemon/daemon.sock"
SLUG="${COFORGE_WORKSPACE_SLUG:-}"
CREDENTIAL="${HOME}/.coforge/computer/credentials/localhost-8789.json"

if [[ ! -x "${BIN}" ]]; then
  echo "[coforge-daemon] missing ${BIN}" >&2
  exit 1
fi

echo "[coforge-daemon] starting supervisor"
"${BIN}" foreground &
DAEMON_PID=$!

cleanup() {
  kill "${DAEMON_PID}" 2>/dev/null || true
  wait "${DAEMON_PID}" 2>/dev/null || true
}
trap cleanup TERM INT

for _ in $(seq 1 100); do
  if [[ -S "${SOCKET}" ]]; then
    break
  fi
  if ! kill -0 "${DAEMON_PID}" 2>/dev/null; then
    echo "[coforge-daemon] supervisor exited before the socket was ready" >&2
    wait "${DAEMON_PID}" || true
    exit 1
  fi
  sleep 0.1
done

if [[ ! -S "${SOCKET}" ]]; then
  echo "[coforge-daemon] supervisor socket did not appear: ${SOCKET}" >&2
  cleanup
  exit 1
fi

BINDINGS="${HOME}/.coforge/daemon/bindings.json"
if [[ -n "${SLUG}" && -f "${CREDENTIAL}" && ! -s "${BINDINGS}" ]]; then
  echo "[coforge-daemon] attaching to workspace ${SLUG}"
  if ! "${BIN}" setup --workspace "${SLUG}" --json; then
    echo "[coforge-daemon] setup failed; supervisor keeps running" >&2
  fi
elif [[ -z "${SLUG}" || ! -f "${CREDENTIAL}" ]]; then
  echo "[coforge-daemon] no workspace credential yet; supervisor is waiting for setup"
fi

wait "${DAEMON_PID}"
