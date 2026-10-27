#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
select_bin="${root}/scripts/select-computer-binary.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

image="${tmp}/image-bin"
printf '#!/bin/sh\necho image\n' > "${image}"
chmod 755 "${image}"

export COFORGE_IMAGE_COMPUTER_BIN="${image}"
export COFORGE_PERSIST_ROOT="${tmp}/volume"
export COFORGE_COMPUTER_INSTALL_ROOT="${tmp}/volume/computer/install"
export COFORGE_COMPUTER_VERSION_FILE="${tmp}/computer-version"
mkdir -p "${COFORGE_PERSIST_ROOT}"

# No recorded version: stay on the image binary and do not invent an install.
got="$("${select_bin}")"
[[ "${got}" == "${image}" ]]
[[ ! -e "${COFORGE_COMPUTER_INSTALL_ROOT}/active.json" ]]

printf '%s\n' '1.2.3' > "${COFORGE_COMPUTER_VERSION_FILE}"
got="$("${select_bin}")"
[[ "${got}" == "${COFORGE_COMPUTER_INSTALL_ROOT}/active/coforge-computer" ]]
[[ "$(readlink "${COFORGE_COMPUTER_INSTALL_ROOT}/active")" == "versions/1.2.3" ]]
grep -q '"current":"1.2.3"' "${COFORGE_COMPUTER_INSTALL_ROOT}/active.json"
grep -q '"schema_version": 2' "${COFORGE_COMPUTER_INSTALL_ROOT}/versions/1.2.3/installation.json"
cmp -s "${image}" "${COFORGE_COMPUTER_INSTALL_ROOT}/versions/1.2.3/coforge-computer"

# A second start keeps the seeded copy.
printf '#!/bin/sh\necho replaced-image\n' > "${image}"
got="$("${select_bin}")"
[[ "${got}" == "${COFORGE_COMPUTER_INSTALL_ROOT}/active/coforge-computer" ]]
grep -q 'echo image' "${got}"

# An already activated newer version is left alone.
rm -rf "${COFORGE_COMPUTER_INSTALL_ROOT}"
mkdir -p "${COFORGE_COMPUTER_INSTALL_ROOT}/versions/9.9.9"
printf '#!/bin/sh\necho upgraded\n' > "${COFORGE_COMPUTER_INSTALL_ROOT}/versions/9.9.9/coforge-computer"
chmod 755 "${COFORGE_COMPUTER_INSTALL_ROOT}/versions/9.9.9/coforge-computer"
ln -sfn "versions/9.9.9" "${COFORGE_COMPUTER_INSTALL_ROOT}/active"
printf '%s\n' '{"schema_version":1,"current":"9.9.9","previous":"1.2.3"}' > "${COFORGE_COMPUTER_INSTALL_ROOT}/active.json"
got="$("${select_bin}")"
[[ "${got}" == "${COFORGE_COMPUTER_INSTALL_ROOT}/active/coforge-computer" ]]
grep -q 'echo upgraded' "${got}"
[[ ! -d "${COFORGE_COMPUTER_INSTALL_ROOT}/versions/1.2.3" ]]

echo "select-computer-binary ok"
