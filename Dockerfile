# Slim Cube sandbox image for db-bridge + Multica + Pi + browser automation.
#
# Runtime policy: all account-scoped tools/config live under root. The extra
# base-image `user` account is removed at the end of the build.

ARG SANDBOX_IMAGE=cube-sandbox-cn.tencentcloudcr.com/cube-sandbox/sandbox-code@sha256:b551b169de85c0216cce9453a8e22059ca47fd3dceced75e918cf1c8de60464b
FROM ${SANDBOX_IMAGE}

ARG NODE_MAJOR=22
ARG INSTALL_PI=1
ARG PI_SUITE_VERSION=0.1.17
ARG PI_SUITE=npm:@lebronj/pi-suite
ARG PI_WORKSPACE_DIR=/workspace
ARG PI_EVOLUTION_ENABLED=1
ARG NPM_REGISTRY=

USER root

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
    PATH=/root/.npm-global/bin:/root/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin

# Minimal OS surface for Pi, Multica daemon, db-bridge calls, VNC/noVNC,
# Chromium, and Playwright-over-system-browser. Avoid doc/debug packages.
RUN apt-get update \
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

RUN mkdir -p /tmp/.X11-unix /workspace/uploads /workspace/browser-shots /data/browser-profile /root/.npm-global \
  && chmod 1777 /tmp/.X11-unix \
  && chown -R root:root /workspace /data/browser-profile /root/.npm-global \
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
COPY scripts/configure-multica-runtime.sh /usr/local/bin/configure-multica-runtime.sh
COPY scripts/start-multica-runtime.sh /usr/local/bin/start-multica-runtime.sh
COPY scripts/cont-init-browser.sh /etc/cont-init.d/99-browser-vnc
RUN chmod +x /entrypoint-vnc.sh \
  /entrypoint-multica-daemon.sh \
  /entrypoint-pi-web.sh \
  /usr/local/bin/cube-start.sh \
  /usr/local/bin/configure-pi-runtime.sh \
  /usr/local/bin/configure-multica-runtime.sh \
  /usr/local/bin/start-multica-runtime.sh \
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

COPY pi-web /opt/pi-web

# Remove the non-root working account inherited from the Cube base image. System
# accounts such as nobody/daemon remain because Debian packages may rely on them.
RUN userdel -r user 2>/dev/null || true \
  && rm -rf /home/user

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/cube-start.sh"]

EXPOSE 5901 6079 6080 9223 49983 49999
