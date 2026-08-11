# Slim Cube sandbox image for db-bridge + Multica + Pi + browser automation.
#
# Runtime policy: all account-scoped tools/config live under root. The extra
# base-image `user` account is removed at the end of the build.

ARG SANDBOX_IMAGE=cube-sandbox-cn.tencentcloudcr.com/cube-sandbox/sandbox-code@sha256:b551b169de85c0216cce9453a8e22059ca47fd3dceced75e918cf1c8de60464b
FROM ${SANDBOX_IMAGE}

ARG NODE_MAJOR=22
ARG INSTALL_PI=1
ARG INSTALL_CURSOR=1
ARG PI_SUITE_VERSION=0.1.17
ARG PI_SUITE=npm:@lebronj/pi-suite
ARG PI_WORKSPACE_DIR=/workspace
ARG PI_EVOLUTION_ENABLED=1
ARG NPM_REGISTRY=
# Debian apt mirror (empty = keep image default sources). China default: Aliyun.
ARG APT_MIRROR=https://mirrors.aliyun.com/debian
ARG APT_SECURITY_MIRROR=https://mirrors.aliyun.com/debian-security

USER root

# Multica daemon is started via `multica daemon supervise` under an outer
# bash restart loop in entrypoint-multica-daemon.sh (no systemd --user in
# Cube/Docker). That combination recovers from crashes and completes Machine
# Upgrade handoffs onto newly staged CLI versions.
ENV HOME=/root \
    PIP_ROOT_USER_ACTION=ignore \
    PYTHONUNBUFFERED=1 \
    ANONYMIZED_TELEMETRY=false \
    DISPLAY=:0 \
    SCREEN_GEOM=1920x1080x24 \
    RESOLUTION=1920x1080x24 \
    RESOLUTION_WIDTH=1920 \
    RESOLUTION_HEIGHT=1080 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    CHROME_REMOTE_DEBUGGING_PORT=9223 \
    CODE_INTERPRETER_HOST=0.0.0.0 \
    CODE_INTERPRETER_PORT=49999 \
    CODE_INTERPRETER_WORKDIR=/workspace \
    MULTICA_DAEMON_MODE=supervise \
    NODE_EXTRA_CA_CERTS=/root/.pi/agent/certs/lenovo-modelfactory-ca.pem \
    LENOVO_MODELFACTORY_HOST=modelfactory.lenovo.com \
    LENOVO_MODELFACTORY_IP=10.110.158.101 \
    LENOVO_DEEPSEEK_PROVIDER=lenovo-deepseek-v4-flash \
    LENOVO_DEEPSEEK_MODEL=DeepSeek-V4-Flash-0731 \
    LENOVO_DEEPSEEK_BASE_URL=https://modelfactory.lenovo.com/service-large-600-1777255649450/llm/v1 \
    LENOVO_DEEPSEEK_AS_DEFAULT=1 \
    PATH=/root/.local/bin:/root/.npm-global/bin:/root/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin

# Minimal OS surface for Pi, Multica daemon, db-bridge calls, VNC/noVNC,
# Chromium, and Playwright-over-system-browser. Avoid doc/debug packages.
RUN set -eux; \
  if [ -n "${APT_MIRROR}" ]; then \
    . /etc/os-release; \
    codename="${VERSION_CODENAME:-bookworm}"; \
    security_mirror="${APT_SECURITY_MIRROR:-${APT_MIRROR}-security}"; \
    # Drop DEB822 sources that would still point at deb.debian.org.
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
    chromium \
    openbox \
    xvfb \
    x11-utils \
    x11vnc \
    xdotool \
    novnc \
    websockify \
    fontconfig \
    fonts-liberation \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
  && mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
  && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
  && apt-get purge -y --auto-remove gnupg \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY novnc-index.html /usr/share/novnc/index.html
COPY lenovo-modelfactory-ca.pem /root/.pi/agent/certs/lenovo-modelfactory-ca.pem

RUN mkdir -p /tmp/.X11-unix /workspace/uploads /workspace/browser-shots /data/browser-profile /root/.npm-global \
    /root/.pi/agent/certs \
  && chmod 644 /root/.pi/agent/certs/lenovo-modelfactory-ca.pem \
  && printf '%s\n' \
       'export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-/root/.pi/agent/certs/lenovo-modelfactory-ca.pem}"' \
       > /etc/profile.d/lenovo-modelfactory-ca.sh \
  && chmod 644 /etc/profile.d/lenovo-modelfactory-ca.sh \
  && chmod 1777 /tmp/.X11-unix \
  && chown -R root:root /workspace /data/browser-profile /root/.npm-global /root/.pi \
  && chmod 755 /workspace /data /data/browser-profile

WORKDIR /workspace

COPY requirements.txt /tmp/leagent-requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/leagent-requirements.txt \
  && rm -f /tmp/leagent-requirements.txt

COPY scripts/entrypoint-vnc.sh /entrypoint-vnc.sh
COPY scripts/entrypoint-multica-daemon.sh /entrypoint-multica-daemon.sh
COPY scripts/entrypoint-pi-web.sh /entrypoint-pi-web.sh
COPY scripts/cube-start.sh /usr/local/bin/cube-start.sh
COPY scripts/configure-pi-runtime.sh /usr/local/bin/configure-pi-runtime.sh
COPY scripts/configure-cursor-runtime.sh /usr/local/bin/configure-cursor-runtime.sh
COPY scripts/configure-multica-runtime.sh /usr/local/bin/configure-multica-runtime.sh
COPY scripts/start-multica-runtime.sh /usr/local/bin/start-multica-runtime.sh
COPY scripts/bake-pi-deepseek.sh /usr/local/bin/bake-pi-deepseek.sh
COPY scripts/cont-init-browser.sh /etc/cont-init.d/99-browser-vnc
RUN chmod +x /entrypoint-vnc.sh \
  /entrypoint-multica-daemon.sh \
  /entrypoint-pi-web.sh \
  /usr/local/bin/cube-start.sh \
  /usr/local/bin/configure-pi-runtime.sh \
  /usr/local/bin/configure-cursor-runtime.sh \
  /usr/local/bin/configure-multica-runtime.sh \
  /usr/local/bin/start-multica-runtime.sh \
  /usr/local/bin/bake-pi-deepseek.sh \
  /etc/cont-init.d/99-browser-vnc

# Multica CLI/daemon is downloaded on the host by scripts/build.sh, then copied.
COPY multica/bin/multica /usr/local/bin/multica
RUN chmod +x /usr/local/bin/multica && multica version

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

RUN ln -sf /root/.npm-global/bin/pi /usr/local/bin/pi \
  && ln -sf /root/.npm-global/bin/pi-mcp-adapter /usr/local/bin/pi-mcp-adapter || true

# Bake Lenovo ModelFactory DeepSeek into the image so Multica/Cube sandboxes
# can use `pi` immediately with no runtime secret injection.
ARG LENOVO_DEEPSEEK_V4_FLASH_API_KEY
ARG LENOVO_DEEPSEEK_PROVIDER=lenovo-deepseek-v4-flash
ARG LENOVO_DEEPSEEK_MODEL=DeepSeek-V4-Flash-0731
ARG LENOVO_DEEPSEEK_BASE_URL=https://modelfactory.lenovo.com/service-large-600-1777255649450/llm/v1
ARG LENOVO_DEEPSEEK_MODEL_NAME=Lenovo ModelFactory DeepSeek V4 Flash
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
      grep -q 'lenovo-deepseek-v4-flash' /root/.pi/agent/models.json; \
      grep -q 'DeepSeek-V4-Flash-0731' /root/.pi/agent/settings.json; \
    fi

# Cursor Agent CLI (headless). Multica daemon auto-detects `cursor-agent` on PATH.
# Auth is runtime-only via CURSOR_API_KEY; do not bake keys into image layers.
RUN if [ "${INSTALL_CURSOR}" != "1" ]; then \
      echo "Skipping Cursor Agent install (INSTALL_CURSOR=${INSTALL_CURSOR})"; \
    else \
      curl -fsSL https://cursor.com/install | bash; \
      mkdir -p /root/.local/bin; \
      if [ -x /root/.local/bin/cursor-agent ]; then \
        ln -sf /root/.local/bin/cursor-agent /usr/local/bin/cursor-agent; \
      elif [ -x /root/.local/bin/agent ]; then \
        ln -sf /root/.local/bin/agent /usr/local/bin/cursor-agent; \
      else \
        echo "ERROR: cursor-agent binary missing after install" >&2; \
        ls -la /root/.local/bin /root/.local/share/cursor-agent 2>/dev/null || true; \
        exit 1; \
      fi; \
      ln -sf /root/.local/bin/agent /usr/local/bin/agent 2>/dev/null || true; \
      cursor-agent --version || /usr/local/bin/cursor-agent --version; \
    fi

# Install WebTTY native deps from lockfile first so source edits do not
# re-download g++/make. node_modules survives the later COPY (context excludes it).
COPY pi-web/package.json pi-web/package-lock.json /opt/pi-web/
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 \
    make \
    g++ \
  && cd /opt/pi-web \
  && npm ci --omit=dev \
  && apt-get purge -y --auto-remove make g++ \
  && rm -rf /var/lib/apt/lists/* /root/.npm/_cacache /tmp/* /var/tmp/*

COPY pi-web /opt/pi-web

# Remove the non-root working account inherited from the Cube base image. System
# accounts such as nobody/daemon remain because Debian packages may rely on them.
RUN userdel -r user 2>/dev/null || true \
  && rm -rf /home/user

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/cube-start.sh"]

EXPOSE 5901 6079 6080 9223 49983 49999
