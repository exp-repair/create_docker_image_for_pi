#!/usr/bin/env bash
# Keep user-installed software and home files on the Computer volume
# (/root/.coforge) so replacing the image does not drop them.
#
# If /opt is already a Docker volume, writes there persist with no extra work.
# Otherwise this script moves /opt trees onto the volume and keeps a watcher
# running so installers that replace a symlink are pulled back without the user
# doing anything.
set -euo pipefail

log() { echo "[persist-user-data] $*"; }

VOLUME="${COFORGE_PERSIST_ROOT:-/root/.coforge}"
APPS="${VOLUME}/apps"
HOME_STORE="${VOLUME}/home"

opt_is_volume() { mountpoint -q /opt 2>/dev/null; }

persist_one() {
  local live="$1"
  local store="$2"

  mkdir -p "$(dirname "${store}")" "$(dirname "${live}")"

  if [[ -L "${live}" ]]; then
    local dest
    dest="$(readlink -n "${live}" || true)"
    if [[ "${dest}" == "${store}" ]]; then
      return 0
    fi
    if [[ -e "${store}" || -d "${store}" ]]; then
      rm -f "${live}"
      ln -sfn "${store}" "${live}"
      log "relink ${live} -> ${store}"
    fi
    return 0
  fi

  if [[ -e "${live}" && ( -e "${store}" || -L "${store}" ) ]]; then
    # Installer unpacked onto overlay after a previous persist. Keep that copy.
    rm -rf "${store}"
    mv "${live}" "${store}"
    ln -sfn "${store}" "${live}"
    log "captured ${live} -> ${store}"
    return 0
  fi

  if [[ -e "${store}" || -L "${store}" ]]; then
    ln -sfn "${store}" "${live}"
    log "link ${live} -> ${store}"
    return 0
  fi

  if [[ -e "${live}" ]]; then
    mv "${live}" "${store}"
    ln -sfn "${store}" "${live}"
    log "moved ${live} -> ${store}"
  fi
}

ensure_home() {
  local name="$1"
  local live="/root/${name}"
  local store="${HOME_STORE}/${name}"
  if [[ ! -e "${store}" && ! -L "${store}" && ! -e "${live}" && ! -L "${live}" ]]; then
    mkdir -p "${store}"
    ln -sfn "${store}" "${live}"
    return 0
  fi
  persist_one "${live}" "${store}"
}

persist_home() {
  ensure_home "projects"
  ensure_home "Desktop"
  ensure_home "Downloads"
  ensure_home "Documents"
  ensure_home ".local"
  ensure_home ".xwechat"
  persist_one "/root/xwechat_files" "${HOME_STORE}/xwechat_files"

  if [[ -d /root/.config ]]; then
    persist_one "/root/.config/xfce4" "${HOME_STORE}/.config/xfce4"
    shopt -s nullglob
    for cfg in /root/.config/*wechat* /root/.config/*WeChat* /root/.config/weixin*; do
      [[ -e "${cfg}" || -L "${cfg}" ]] || continue
      persist_one "${cfg}" "${HOME_STORE}/.config/$(basename "${cfg}")"
    done
    shopt -u nullglob
  fi
}

restore_opt_launchers() {
  if [[ -x /opt/wechat/wechat ]]; then
    ln -sfn /opt/wechat/wechat /usr/bin/wechat
  fi
  local devtools="/opt/apps/io.github.msojocs.wechat-devtools-linux/files/bin/bin/wechat-devtools"
  if [[ -x "${devtools}" && ! -e /usr/local/bin/wechat-devtools-open.sh ]]; then
    cat > /usr/local/bin/wechat-devtools-open.sh <<EOF
#!/bin/bash
if [[ \$# -eq 0 && -d /root/projects/wechatapp ]]; then
  exec "${devtools}" /root/projects/wechatapp
fi
exec "${devtools}" "\$@"
EOF
    chmod 755 /usr/local/bin/wechat-devtools-open.sh
    log "restored /usr/local/bin/wechat-devtools-open.sh"
  fi
}

copy_opt_desktops() {
  local apps_dir="/root/.local/share/applications"
  mkdir -p "${apps_dir}"
  [[ -d /usr/share/applications ]] || return 0
  shopt -s nullglob
  for desktop in /usr/share/applications/*.desktop; do
    [[ -f "${desktop}" ]] || continue
    if grep -Eq '^Exec=.*/opt/' "${desktop}"; then
      dest="${apps_dir}/$(basename "${desktop}")"
      if [[ ! -e "${dest}" ]]; then
        cp -a "${desktop}" "${dest}"
        log "copied $(basename "${desktop}") -> ${apps_dir}"
      fi
    fi
  done
  shopt -u nullglob
}

persist_opt() {
  if opt_is_volume; then
    mkdir -p /opt
    if [[ -d "${APPS}" ]]; then
      shopt -s nullglob
      for entry in "${APPS}"/*; do
        [[ -e "${entry}" || -L "${entry}" ]] || continue
        local name dest
        name="$(basename "${entry}")"
        dest="/opt/${name}"
        if [[ ! -e "${dest}" && ! -L "${dest}" ]]; then
          cp -a "${entry}" "${dest}"
          log "seeded ${dest} from ${APPS}"
        fi
      done
      shopt -u nullglob
    fi
    restore_opt_launchers
    return 0
  fi
  [[ -d /opt ]] || return 0
  shopt -s nullglob
  # After an image replace /opt is empty; put store trees back first.
  for store in "${APPS}"/*; do
    [[ -e "${store}" || -L "${store}" ]] || continue
    persist_one "/opt/$(basename "${store}")" "${store}"
  done
  for entry in /opt/*; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    persist_one "${entry}" "${APPS}/$(basename "${entry}")"
  done
  shopt -u nullglob
  copy_opt_desktops
  restore_opt_launchers
}

if [[ ! -d "${VOLUME}" ]]; then
  log "skip: ${VOLUME} is missing"
  exit 0
fi

mkdir -p "${APPS}" "${HOME_STORE}"

if [[ "${1:-}" == "--watch" ]]; then
  while true; do
    persist_opt || true
    sleep 3
  done
fi

persist_home
persist_opt
