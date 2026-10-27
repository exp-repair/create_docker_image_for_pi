#!/usr/bin/env bash
# Pick the Computer binary for this container.
#
# An upgraded copy on the data volume wins, so replacing the image is not
# required to run a newer coforge-computer. An empty volume is seeded from the
# image binary in the installer's layout (versions/<version>, active.json),
# which a later upgrade can verify. The image binary remains the fallback.
set -euo pipefail

IMAGE_BIN="${COFORGE_IMAGE_COMPUTER_BIN:-/usr/local/bin/coforge-computer}"
VOLUME="${COFORGE_PERSIST_ROOT:-/root/.coforge}"
INSTALL="${COFORGE_COMPUTER_INSTALL_ROOT:-${VOLUME}/computer/install}"
VERSION_FILE="${COFORGE_COMPUTER_VERSION_FILE:-/usr/local/share/coforge/computer-version}"

log() { echo "[select-computer-binary] $*" >&2; }

valid_version() {
  local version="$1"
  [[ "${version}" =~ ^[A-Za-z0-9.+-]{1,100}$ ]] \
    && [[ "${version}" != "." ]] \
    && [[ "${version}" != -* ]] \
    && [[ "${version}" != *..* ]]
}

identity_json() {
  local path="$1"
  local size checksum
  size="$(stat -c%s "${path}")"
  checksum="$(sha256sum "${path}" | awk '{print $1}')"
  printf '{"size": %s, "checksum": "%s"}' "${size}" "${checksum}"
}

# coforge-daemon-boot.sh used to make active/ a directory whose binary is a
# symlink back to the image. That is not an installer activation.
legacy_image_link() {
  [[ -d "${INSTALL}/active" && ! -L "${INSTALL}/active" ]] || return 1
  [[ -L "${INSTALL}/active/coforge-computer" ]] || return 1
  local target image
  target="$(readlink -f "${INSTALL}/active/coforge-computer" 2>/dev/null || true)"
  image="$(readlink -f "${IMAGE_BIN}" 2>/dev/null || true)"
  [[ -n "${target}" && "${target}" == "${image}" ]]
}

seed_image_version() {
  local version="$1"
  local dest="${INSTALL}/versions/${version}"
  if [[ -e "${INSTALL}/active.json" || -e "${dest}" ]]; then
    return 0
  fi
  if [[ -e "${INSTALL}/active" ]]; then
    if legacy_image_link; then
      rm -rf "${INSTALL}/active"
    else
      log "leave existing ${INSTALL}/active in place"
      return 0
    fi
  fi
  mkdir -p "${INSTALL}/versions"
  local stage
  stage="$(mktemp -d "${INSTALL}/versions/.seed.XXXXXX")"
  cp -a "${IMAGE_BIN}" "${stage}/coforge-computer"
  chmod 755 "${stage}/coforge-computer"
  printf '%s\n' '#!/bin/sh' 'exec "${0%/*}/coforge-computer" __agent-cli "$@"' > "${stage}/coforge"
  chmod 755 "${stage}/coforge"
  printf '%s\n' "${version}" > "${stage}/version"
  chmod 600 "${stage}/version"
  cat > "${stage}/installation.json" <<EOF
{
  "schema_version": 2,
  "version": "${version}",
  "computer": $(identity_json "${stage}/coforge-computer"),
  "agentCli": $(identity_json "${stage}/coforge")
}
EOF
  chmod 600 "${stage}/installation.json"
  mv "${stage}" "${dest}"
  ln -sfn "versions/${version}" "${INSTALL}/active"
  cat > "${INSTALL}/active.json" <<EOF
{"schema_version":1,"current":"${version}","previous":null}
EOF
  chmod 600 "${INSTALL}/active.json"
  log "seeded ${version} from the image"
}

activated="${INSTALL}/active/coforge-computer"
if [[ -d "${VOLUME}" && -x "${IMAGE_BIN}" && ! -e "${INSTALL}/active.json" && -f "${VERSION_FILE}" ]]; then
  version="$(tr -d '[:space:]' < "${VERSION_FILE}")"
  if valid_version "${version}"; then
    seed_image_version "${version}"
  else
    log "skip seed: image version is not a release version"
  fi
fi

if [[ -x "${activated}" && -f "${INSTALL}/active.json" ]]; then
  printf '%s\n' "${activated}"
  exit 0
fi

printf '%s\n' "${IMAGE_BIN}"
