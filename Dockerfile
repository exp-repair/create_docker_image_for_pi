# Staging Swarm computer image. The host starts this image with no command.
# The entrypoint keeps the desktop listeners up and runs `coforge-computer
# foreground` as a child. The host injects the binding environment; this image
# does not run `setup --workspace`.
# Pi, DeepSeek, and the Lenovo CA stay in the image. The desktop is a slim
# XFCE session: Chromium, Thunar, and a terminal, with the CoForge mark on
# the wallpaper. It stays down until a client connects.

ARG SANDBOX_IMAGE=cube-sandbox-cn.tencentcloudcr.com/cube-sandbox/sandbox-code@sha256:b551b169de85c0216cce9453a8e22059ca47fd3dceced75e918cf1c8de60464b
FROM ${SANDBOX_IMAGE}

ARG NODE_MAJOR=22
ARG INSTALL_PI=1
ARG PI_SUITE_VERSION=0.1.17
ARG PI_SUITE=npm:@lebronj/pi-suite
ARG PI_WORKSPACE_DIR=/workspace
ARG PI_EVOLUTION_ENABLED=1
ARG NPM_REGISTRY=
# Debian apt mirror (empty = keep image default sources). China default: Tencent.
ARG APT_MIRROR=https://mirrors.cloud.tencent.com/debian
ARG APT_SECURITY_MIRROR=https://mirrors.cloud.tencent.com/debian-security
ARG COMPUTER_VERSION=

USER root

ENV HOME=/root \
    PYTHONUNBUFFERED=1 \
    PI_WEB_HOST=0.0.0.0 \
    PI_WEB_PORT=6079 \
    PI_WEB_WORKSPACE=/workspace \
    PI_WEB_TERM_SHELL=/bin/bash \
    PI_WEB_CONSOLE=0 \
    NODE_EXTRA_CA_CERTS=/root/.pi/agent/certs/lenovo-modelfactory-ca.pem \
    LENOVO_MODELFACTORY_HOST=modelfactory.lenovo.com \
    LENOVO_MODELFACTORY_IP=10.110.158.101 \
    LENOVO_DEEPSEEK_PROVIDER=openai \
    LENOVO_DEEPSEEK_MODEL=DeepSeek \
    LENOVO_DEEPSEEK_BASE_URL=https://modelfactory.lenovo.com/llm/v1 \
    LENOVO_DEEPSEEK_AS_DEFAULT=1 \
    NODE_OPTIONS=--require=/usr/local/lib/lenovo-modelfactory-dns-hook.js \
    PATH=/root/.local/bin:/root/.npm-global/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin

# Terminal toolkit, Node, and a slim XFCE desktop. TigerVNC stays stopped until
# a client connects. Port 5901 is raw VNC. Port 6080 is the browser WebSocket.
# novnc's Python stack (numpy, websockify, oslo) is removed after install; the
# image serves /usr/share/novnc itself.
RUN set -eux; \
  if [ -n "${APT_MIRROR}" ]; then \
    . /etc/os-release; \
    codename="${VERSION_CODENAME:-bookworm}"; \
    security_mirror="${APT_SECURITY_MIRROR:-${APT_MIRROR}-security}"; \
    rm -f /etc/apt/sources.list.d/debian.sources \
          /etc/apt/sources.list.d/debian-security.sources \
          /etc/apt/sources.list.d/*.sources 2>/dev/null || true; \
    printf '%s\n' \
      "deb ${APT_MIRROR} ${codename} main contrib non-free non-free-firmware" \
      "deb ${APT_MIRROR} ${codename}-updates main contrib non-free non-free-firmware" \
      "deb ${security_mirror} ${codename}-security main contrib non-free non-free-firmware" \
      > /etc/apt/sources.list; \
    echo "Using APT mirror: ${APT_MIRROR}"; \
  fi; \
  apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gzip \
    gnupg \
    git \
    jq \
    procps \
    iproute2 \
    fd-find \
    file \
    less \
    nano \
    vim-tiny \
    ripgrep \
    dbus-x11 \
    fonts-dejavu-core \
    fonts-noto-cjk \
    tigervnc-standalone-server \
    novnc \
    librsvg2-bin \
    xfce4-session \
    xfwm4 \
    xfdesktop4 \
    xfce4-panel \
    thunar \
    xfce4-terminal \
    python3-gi \
    python3-pip \
    python3-venv \
    gir1.2-gtk-3.0 \
    chromium \
  && mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
  && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
  && for pkg in \
       python3-novnc python3-numpy python3-websockify websockify \
       python3-oslo.config python3-oslo.context python3-oslo.i18n \
       python3-oslo.log python3-oslo.serialization python3-oslo.utils \
       gnupg; do \
       if dpkg -s "$pkg" >/dev/null 2>&1; then dpkg --force-depends --purge "$pkg"; fi; \
     done \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Lightweight system packages only (no Playwright — it balloons image build time).
# Runtime pip goes into /root/.coforge/venv (see persist-user-data.sh).
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
ARG PIP_TRUSTED_HOST=mirrors.aliyun.com
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PIP_INDEX_URL=${PIP_INDEX_URL} \
    PIP_TRUSTED_HOST=${PIP_TRUSTED_HOST}
COPY requirements.txt /tmp/requirements.txt
RUN set -eux; \
  printf '%s\n' \
    '[global]' \
    "index-url = ${PIP_INDEX_URL}" \
    "trusted-host = ${PIP_TRUSTED_HOST}" \
    'timeout = 60' \
    > /etc/pip.conf; \
  mkdir -p /root/.config/pip; \
  cp /etc/pip.conf /root/.config/pip/pip.conf; \
  pip_args="--no-cache-dir --break-system-packages"; \
  if [ -n "${PIP_INDEX_URL}" ]; then \
    pip_args="${pip_args} -i ${PIP_INDEX_URL}"; \
  fi; \
  if [ -n "${PIP_TRUSTED_HOST}" ]; then \
    pip_args="${pip_args} --trusted-host ${PIP_TRUSTED_HOST}"; \
  fi; \
  # shellcheck disable=SC2086
  pip3 install ${pip_args} -r /tmp/requirements.txt; \
  rm -f /tmp/requirements.txt

COPY lenovo-modelfactory-ca.pem /root/.pi/agent/certs/lenovo-modelfactory-ca.pem
COPY scripts/lenovo-modelfactory-dns-hook.js /usr/local/lib/lenovo-modelfactory-dns-hook.js

RUN mkdir -p /workspace /root/.npm-global /root/.pi/agent/certs \
  && chmod 644 /root/.pi/agent/certs/lenovo-modelfactory-ca.pem \
  && printf '%s\n' \
       'export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-/root/.pi/agent/certs/lenovo-modelfactory-ca.pem}"' \
       > /etc/profile.d/lenovo-modelfactory-ca.sh \
  && chmod 644 /etc/profile.d/lenovo-modelfactory-ca.sh \
  && chown -R root:root /workspace /root/.npm-global /root/.pi \
  && chmod 755 /workspace

WORKDIR /workspace

COPY coforge/coforge-computer /usr/local/bin/coforge-computer
LABEL org.coforge.computer.version=${COMPUTER_VERSION}
COPY scripts/bake-pi-deepseek.sh /usr/local/bin/bake-pi-deepseek.sh
COPY scripts/container-systemctl /usr/local/bin/systemctl
COPY config/pi-modelfactory-provider.json /usr/local/share/coforge/pi-modelfactory-provider.json
COPY config/pi-agent/APPEND_SYSTEM.md /usr/local/share/coforge/pi-APPEND_SYSTEM.md
COPY config/pi-agent/skills/ /usr/local/share/coforge/pi-skills/
RUN chmod 755 /usr/local/bin/coforge-computer \
  /usr/local/bin/bake-pi-deepseek.sh \
  /usr/local/bin/systemctl \
  && chmod 644 /usr/local/share/coforge/pi-APPEND_SYSTEM.md \
  && find /usr/local/share/coforge/pi-skills -type f -name 'SKILL.md' -exec chmod 644 {} +

RUN npm config set prefix /root/.npm-global \
  && npm config set fetch-retries 5 \
  && npm config set fetch-retry-mintimeout 20000 \
  && npm config set fetch-retry-maxtimeout 120000 \
  && npm config set fetch-timeout 300000

RUN if [ "${INSTALL_PI}" != "1" ]; then \
      echo "Skipping Pi install (INSTALL_PI=${INSTALL_PI})"; \
    else \
      if [ -n "${NPM_REGISTRY}" ]; then \
        npm config set registry "${NPM_REGISTRY}"; \
        echo "Using npm registry: ${NPM_REGISTRY}"; \
      fi; \
      npm install -g --ignore-scripts @earendil-works/pi-coding-agent; \
      mkdir -p /root/.pi/agent; \
      PI_SUITE_SOURCE="${PI_SUITE}"; \
      if [ "${PI_SUITE}" = "npm:@lebronj/pi-suite" ] && [ -n "${PI_SUITE_VERSION}" ]; then \
        PI_SUITE_SOURCE="npm:@lebronj/pi-suite@${PI_SUITE_VERSION}"; \
      fi; \
      pi install "${PI_SUITE_SOURCE}"; \
    fi

RUN ln -sf /root/.npm-global/bin/pi /usr/local/bin/pi.real \
  && printf '%s\n' \
       '#!/usr/bin/env bash' \
       'export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-/root/.pi/agent/certs/lenovo-modelfactory-ca.pem}"' \
       'export NODE_OPTIONS="${NODE_OPTIONS:---require=/usr/local/lib/lenovo-modelfactory-dns-hook.js}"' \
       'exec /usr/local/bin/pi.real "$@"' \
       > /usr/local/bin/pi \
  && chmod +x /usr/local/bin/pi \
  && ln -sf /root/.npm-global/bin/pi-mcp-adapter /usr/local/bin/pi-mcp-adapter || true

# Remove the non-root working account inherited from the Cube base image. System
# accounts such as nobody/daemon remain because Debian packages may rely on them.
RUN userdel -r user 2>/dev/null || true \
  && rm -rf /home/user

RUN printf '%s\n' '#!/bin/sh' 'exec /usr/local/bin/coforge-computer __agent-cli "$@"' \
      > /usr/local/bin/coforge \
  && chmod 755 /usr/local/bin/coforge

# Optional host snapshot of Pi agent files. Copied first so the bake step below
# always overwrites apiKey from LENOVO_DEEPSEEK_* build-args (pi.env).
# APPEND_SYSTEM.md and skills are always installed from share templates so Pi
# knows it is a CoForge cloud-computer agent with browser/desktop capabilities.
COPY config/pi-agent/ /tmp/pi-agent/
RUN mkdir -p /root/.pi/agent/certs /root/.pi/agent/skills \
  && cp /usr/local/share/coforge/pi-APPEND_SYSTEM.md /root/.pi/agent/APPEND_SYSTEM.md \
  && chmod 644 /root/.pi/agent/APPEND_SYSTEM.md \
  && for skill_name in cloud-computer-overview browser-login; do \
       rm -rf "/root/.pi/agent/skills/${skill_name}"; \
       cp -a "/usr/local/share/coforge/pi-skills/${skill_name}" "/root/.pi/agent/skills/${skill_name}"; \
     done \
  && if [ -f /tmp/pi-agent/models.json ]; then \
      cp /tmp/pi-agent/models.json /root/.pi/agent/models.json; \
      if [ -f /tmp/pi-agent/settings.json ]; then cp /tmp/pi-agent/settings.json /root/.pi/agent/settings.json; fi; \
      if [ -d /tmp/pi-agent/certs ]; then cp -a /tmp/pi-agent/certs/. /root/.pi/agent/certs/; fi; \
      chmod 600 /root/.pi/agent/models.json; \
      chmod 644 /root/.pi/agent/certs/* 2>/dev/null || true; \
    fi; \
    rm -rf /tmp/pi-agent

# Bake after the snapshot copy so a stale config/pi-agent/models.json cannot
# clobber the key from pi.env.
ARG LENOVO_DEEPSEEK_V4_FLASH_API_KEY
ARG LENOVO_DEEPSEEK_PROVIDER=openai
ARG LENOVO_DEEPSEEK_MODEL=DeepSeek
ARG LENOVO_DEEPSEEK_BASE_URL=https://modelfactory.lenovo.com/llm/v1
ARG LENOVO_DEEPSEEK_MODEL_NAME=DeepSeek
RUN if [ "${INSTALL_PI}" != "1" ]; then \
      echo "Skipping DeepSeek bake (INSTALL_PI=${INSTALL_PI})"; \
    elif [ -z "${LENOVO_DEEPSEEK_V4_FLASH_API_KEY}" ]; then \
      echo "ERROR: LENOVO_DEEPSEEK_V4_FLASH_API_KEY build-arg is required to bake DeepSeek" >&2; \
      exit 1; \
    else \
      LENOVO_DEEPSEEK_V4_FLASH_API_KEY="${LENOVO_DEEPSEEK_V4_FLASH_API_KEY}" \
      LENOVO_DEEPSEEK_PROVIDER="${LENOVO_DEEPSEEK_PROVIDER}" \
      LENOVO_DEEPSEEK_MODEL="${LENOVO_DEEPSEEK_MODEL}" \
      LENOVO_DEEPSEEK_BASE_URL="${LENOVO_DEEPSEEK_BASE_URL}" \
      LENOVO_DEEPSEEK_MODEL_NAME="${LENOVO_DEEPSEEK_MODEL_NAME}" \
      /usr/local/bin/bake-pi-deepseek.sh; \
      test -f /root/.pi/agent/models.json; \
      test -f /root/.pi/agent/settings.json; \
      test -f /root/.pi/agent/model-factory.env; \
      test -f /root/.pi/agent/APPEND_SYSTEM.md; \
      grep -q 'CoForge' /root/.pi/agent/APPEND_SYSTEM.md; \
      test -f /root/.pi/agent/skills/cloud-computer-overview/SKILL.md; \
      test -f /root/.pi/agent/skills/browser-login/SKILL.md; \
      grep -q 'name: browser-login' /root/.pi/agent/skills/browser-login/SKILL.md; \
      grep -q 'https://modelfactory.lenovo.com/llm/v1' /root/.pi/agent/models.json; \
      grep -q '"id": "DeepSeek"' /root/.pi/agent/models.json; \
      grep -q '"defaultModel": "DeepSeek"' /root/.pi/agent/settings.json; \
    fi

COPY scripts/persist-user-data.sh /usr/local/bin/persist-user-data.sh
COPY scripts/select-computer-binary.sh /usr/local/bin/select-computer-binary.sh
COPY scripts/activate-computer-release.sh /usr/local/bin/activate-computer-release.sh
COPY scripts/supervise-computer-runtime.sh /usr/local/bin/supervise-computer-runtime.sh
COPY scripts/restart-computer-runtime.sh /usr/local/bin/restart-computer-runtime.sh
COPY scripts/entrypoint-foreground.sh /usr/local/bin/entrypoint-foreground.sh
COPY scripts/vnc-ondemand.py /usr/local/bin/vnc-ondemand.py
COPY scripts/vnc-websocket.py /usr/local/bin/vnc-websocket.py
COPY scripts/page-fill.py /usr/local/bin/page-fill.py
COPY scripts/vnc-xstartup /usr/local/share/coforge/vnc-xstartup
COPY scripts/vnc-agent-xstartup /usr/local/share/coforge/vnc-agent-xstartup
COPY scripts/vnc-agent-screen.py /usr/local/bin/vnc-agent-screen.py
COPY scripts/vnc-desktop.html /usr/local/share/coforge/vnc-desktop.html
COPY scripts/coforge_cdp.py /usr/local/lib/coforge/coforge_cdp.py
COPY scripts/coforge-chromium.py /usr/local/bin/coforge-chromium
COPY scripts/coforge-cdp-endpoint /usr/local/bin/coforge-cdp-endpoint
COPY scripts/coforge_x11.py /usr/local/lib/coforge/coforge_x11.py
COPY scripts/coforge-launcher-focus.py /usr/local/bin/coforge-launcher-focus
COPY scripts/coforge-dock-ui.py /usr/local/bin/coforge-dock-ui
COPY scripts/coforge-thunar.sh /usr/local/bin/coforge-thunar
COPY scripts/coforge-terminal /usr/local/bin/coforge-terminal
COPY scripts/coforge-dock /usr/local/bin/coforge-dock
COPY scripts/coforge-maximize-chromium /usr/local/bin/coforge-maximize-chromium
COPY config/desktop-wallpaper-preview.png /usr/local/share/coforge/desktop-logo.png
COPY config/xfce/xfce4-desktop.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml
COPY config/xfce/xfce4-panel.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml
COPY config/xfce/xfwm4.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml
COPY config/xfce/xfce4-session.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml
COPY config/xfce/applications/coforge-chromium.desktop /usr/share/applications/coforge-chromium.desktop
COPY config/xfce/applications/coforge-terminal.desktop /usr/share/applications/coforge-terminal.desktop
COPY config/xfce/applications/coforge-thunar.desktop /usr/share/applications/coforge-thunar.desktop
COPY config/gtk-3.0/gtk.css /etc/xdg/gtk-3.0/gtk.css
COPY config/chromium/policies/managed/coforge.json /etc/chromium/policies/managed/coforge.json
COPY config/chromium/policies/managed/lenovo-intranet.json.template /usr/local/share/coforge/lenovo-intranet.json.template
COPY config/profile.d/corp-proxy.sh /usr/local/share/coforge/corp-proxy.sh
COPY config/certs/lenovo-sha2-root.crt /usr/local/share/ca-certificates/lenovo-sha2-root.crt
COPY config/certs/lenovo-sha2-subca1.crt /usr/local/share/ca-certificates/lenovo-sha2-subca1.crt
COPY scripts/render-lenovo-proxy.sh /usr/local/bin/render-lenovo-proxy.sh
RUN update-ca-certificates \
  && chmod 755 /usr/local/bin/render-lenovo-proxy.sh \
  && chmod 644 /usr/local/share/coforge/lenovo-intranet.json.template \
      /usr/local/share/coforge/corp-proxy.sh \
      /usr/local/share/ca-certificates/lenovo-sha2-root.crt \
      /usr/local/share/ca-certificates/lenovo-sha2-subca1.crt \
  && openssl x509 -in /usr/local/share/ca-certificates/lenovo-sha2-root.crt -noout -subject \
    | grep -q 'SHA2ROOTCA' \
  && openssl x509 -in /usr/local/share/ca-certificates/lenovo-sha2-subca1.crt -noout -subject \
    | grep -q 'lenovoSHA2SUBCA1'
RUN mkdir -p /usr/local/lib/coforge /usr/local/share/coforge \
  && if [ -n "${COMPUTER_VERSION}" ]; then printf '%s\n' "${COMPUTER_VERSION}" > /usr/local/share/coforge/computer-version; fi \
  && chmod 755 /usr/local/bin/persist-user-data.sh \
      /usr/local/bin/select-computer-binary.sh \
      /usr/local/bin/activate-computer-release.sh \
      /usr/local/bin/supervise-computer-runtime.sh \
      /usr/local/bin/restart-computer-runtime.sh \
      /usr/local/bin/entrypoint-foreground.sh \
      /usr/local/bin/vnc-ondemand.py \
      /usr/local/bin/vnc-websocket.py \
      /usr/local/bin/page-fill.py \
      /usr/local/bin/vnc-agent-screen.py \
      /usr/local/bin/coforge-chromium \
      /usr/local/bin/coforge-cdp-endpoint \
      /usr/local/lib/coforge/coforge_cdp.py \
      /usr/local/bin/coforge-launcher-focus \
      /usr/local/bin/coforge-dock-ui \
      /usr/local/bin/coforge-thunar \
      /usr/local/bin/coforge-terminal \
      /usr/local/bin/coforge-dock \
      /usr/local/bin/coforge-maximize-chromium \
      /usr/local/share/coforge/vnc-xstartup \
      /usr/local/share/coforge/vnc-agent-xstartup \
  && mkdir -p /usr/local/share/coforge /root/.vnc \
  && ln -sfn /usr/local/share/coforge/vnc-xstartup /root/.vnc/xstartup \
  && rm -rf /root/.cache /root/.npm \
      /usr/bin/envd \
      /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/uvicorn /usr/local/bin/fastapi \
      /usr/local/bin/start-lightweight-code-interpreter.sh \
      /opt/lightweight-code-interpreter \
  && dpkg --purge librsvg2-bin \
  && command -v tigervncserver \
  && command -v startxfce4 \
  && ln -sfn coforge-chromium /usr/local/bin/chromium \
  && command -v chromium \
  && test -f /usr/share/novnc/core/rfb.js \
  && test -f /usr/local/share/coforge/vnc-desktop.html \
  && test -f /usr/local/share/coforge/desktop-logo.png \
  && test -f /etc/chromium/policies/managed/coforge.json \
  && grep -q '"PasswordManagerEnabled": false' /etc/chromium/policies/managed/coforge.json \
  && grep -q 'placement_ratio' /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml \
  && grep -q 'show_dock_shadow' /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml \
  && grep -q 'autohide-size: 48' /etc/xdg/gtk-3.0/gtk.css \
  && grep -q '<property name="panels" type="array">' /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml \
  && ! grep -q '>xfce4-panel<' /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml \
  && test -x /usr/local/bin/coforge-dock-ui \
  && test -x /usr/local/bin/coforge-thunar \
  && grep -q 'coforge-dock-ui' /usr/local/share/coforge/vnc-xstartup \
  && grep -q 'coforge-dock-ui' /usr/local/share/coforge/vnc-agent-xstartup \
  && grep -q '.coforge-dock' /etc/xdg/gtk-3.0/gtk.css \
  && grep -q -- '--start-maximized' /usr/local/bin/coforge-chromium \
  && grep -q 'coforge-cdp' /usr/local/bin/coforge-chromium \
  && test -x /usr/local/bin/coforge-cdp-endpoint \
  && test -f /usr/local/lib/coforge/coforge_cdp.py \
  && test -x /usr/local/bin/coforge-terminal \
  && test -x /usr/local/bin/coforge-maximize-chromium \
  && test -x /usr/local/bin/persist-user-data.sh \
  && grep -q 'persist_workspace' /usr/local/bin/persist-user-data.sh \
  && grep -q 'ensure_venv' /usr/local/bin/persist-user-data.sh \
  && python3 -c 'import venv' \
  && test -x /usr/local/bin/select-computer-binary.sh \
  && test -x /usr/local/bin/activate-computer-release.sh \
  && test -x /usr/local/bin/supervise-computer-runtime.sh \
  && test -x /usr/local/bin/restart-computer-runtime.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint-foreground.sh"]

EXPOSE 5901 6080
