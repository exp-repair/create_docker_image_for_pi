#!/usr/bin/env bash
# Runs after systemd is up. Starts a root user manager, then the Computer
# supervisor, then attaches this container to COFORGE_WORKSPACE_SLUG.
set -euo pipefail

export HOME=/root
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
SLUG="${COFORGE_WORKSPACE_SLUG:-my}"
BIN=/usr/local/bin/coforge-computer

mkdir -p /var/lib/systemd/linger "${XDG_RUNTIME_DIR}" /etc/systemd/user.conf.d
touch /var/lib/systemd/linger/root
chmod 700 "${XDG_RUNTIME_DIR}"
# Node does not use the system trust store. Workspace daemons are systemd --user
# services, so Pi only sees the Lenovo CA when the user manager passes it down.
CA_CERT="${NODE_EXTRA_CA_CERTS:-/root/.pi/agent/certs/lenovo-modelfactory-ca.pem}"
if [[ -f "${CA_CERT}" ]]; then
  printf '%s\n' '[Manager]' "DefaultEnvironment=NODE_EXTRA_CA_CERTS=${CA_CERT}" \
    > /etc/systemd/user.conf.d/lenovo-ca.conf
fi
systemctl start user@0.service
for _ in $(seq 1 50); do
  if [[ -S "${XDG_RUNTIME_DIR}/bus" ]]; then
    break
  fi
  sleep 0.1
done

install -d -m 700 /root/.coforge/computer/install/active
ln -sfn "${BIN}" /root/.coforge/computer/install/active/coforge-computer
# Agents are told to run `coforge message check`. That entry is a thin wrapper
# around the computer binary, and it has to sit beside it.
cat > /usr/local/bin/coforge <<'EOF'
#!/bin/sh
exec /usr/local/bin/coforge-computer __agent-cli "$@"
EOF
chmod 755 /usr/local/bin/coforge

echo "[coforge-daemon] starting supervisor"
"${BIN}" foreground &

SOCKET=/root/.coforge/daemon/daemon.sock
for _ in $(seq 1 100); do
  if [[ -S "${SOCKET}" ]]; then
    break
  fi
  sleep 0.1
done
if [[ ! -S "${SOCKET}" ]]; then
  echo "[coforge-daemon] supervisor socket missing" >&2
  exit 1
fi

echo "[coforge-daemon] attaching to workspace ${SLUG}"
"${BIN}" setup --workspace "${SLUG}" --json
"${BIN}" status --json
# Keep the boot service alive so systemd does not tear the supervisor down.
wait
