#!/usr/bin/env bash
# Register the VNC longrun service into sandbox-code s6-rc user bundle.
set -euo pipefail

SERVICES=(playwright-vnc multica-daemon pi-web)
S6_RC=/etc/s6-overlay/s6-rc.d

mkdir -p "${S6_RC}/user/contents.d"
if [[ ! -f "${S6_RC}/user/type" ]]; then
  echo bundle > "${S6_RC}/user/type"
fi

for service in "${SERVICES[@]}"; do
  [[ -d "${S6_RC}/${service}" ]] || continue
  chmod +x "${S6_RC}/${service}/run"
  touch "${S6_RC}/user/contents.d/${service}"
done

for parent in default img bundle top ci-services; do
  [[ -d "${S6_RC}/${parent}/contents.d" ]] || continue
  [[ -f "${S6_RC}/${parent}/type" ]] && grep -qx bundle "${S6_RC}/${parent}/type" || continue
  touch "${S6_RC}/${parent}/contents.d/user" 2>/dev/null || true
done

find "${S6_RC}" -maxdepth 3 \( -name type -o -path '*/contents.d/*' \) -print 2>/dev/null \
  | sort > /etc/s6-overlay/playwright-vnc-registration.log || true

echo "[register-s6] registered: ${SERVICES[*]}"
