# Leagent Cube/E2B sandbox template — aligned with River (Daytona) tool contracts.
#
# Installs only what the e2b-code-interpreter base lacks:
# - VNC live view (:0 / :5901 / :6080)
# - system Chromium + Leagent CDP bootstrap (:9223)
# - /workspace layout + River-style CLI/Python tools
#
# Build: ./scripts/build.sh

ARG SANDBOX_IMAGE=cube-sandbox-image.tencentcloudcr.com/demo/e2b-code-interpreter:v1.1-data
FROM ${SANDBOX_IMAGE}

ARG NOVNC_ARCHIVE_URL=

USER root

ENV PIP_ROOT_USER_ACTION=ignore
ENV PYTHONUNBUFFERED=1
ENV ANONYMIZED_TELEMETRY=false
ENV DISPLAY=:0
ENV SCREEN_GEOM=1920x1080x24
ENV RESOLUTION=1920x1080x24
ENV RESOLUTION_WIDTH=1920
ENV RESOLUTION_HEIGHT=1080
ENV VNC_PORT=5901
ENV NOVNC_PORT=6080

# --- VNC + browser (Cube-specific; River gets these from daytonaio/sandbox) ---
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    chromium \
    xdotool \
    openbox \
    xvfb \
    x11-utils \
    x11vnc \
    websockify \
    fontconfig \
    fonts-liberation \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
  && mkdir -p /usr/share \
  && set -eux; \
     fetch_novnc() { \
       curl -fsSL \
         --connect-timeout 120 \
         --max-time 3600 \
         --retry 6 \
         --retry-delay 15 \
         --retry-all-errors \
         -o /tmp/novnc.tgz \
         "$1"; \
     }; \
     if [ -n "${NOVNC_ARCHIVE_URL}" ]; then \
       fetch_novnc "${NOVNC_ARCHIVE_URL}"; \
     else \
       fetch_novnc "https://github.com/novnc/noVNC/archive/refs/tags/v1.7.0.tar.gz" \
       || fetch_novnc "https://ghproxy.net/https://github.com/novnc/noVNC/archive/refs/tags/v1.7.0.tar.gz" \
       || fetch_novnc "https://kgithub.com/noVNC/noVNC/archive/refs/tags/v1.7.0.tar.gz"; \
     fi \
  && tar xzf /tmp/novnc.tgz -C /tmp \
  && rm -f /tmp/novnc.tgz \
  && mv /tmp/noVNC-1.7.0 /usr/share/novnc \
  && rm -rf /tmp/noVNC-* \
  && rm -rf /var/lib/apt/lists/*

# --- Agent CLI tools (same set as backend/core/sandbox/docker/Dockerfile) ---
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    antiword \
    catdoc \
    csvkit \
    fd-find \
    file \
    gawk \
    jq \
    less \
    poppler-utils \
    ripgrep \
    rsync \
    tree \
    unrtf \
    vim \
    xmlstarlet \
  && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
  && rm -rf /var/lib/apt/lists/*

COPY novnc-index.html /usr/share/novnc/index.html

RUN mkdir -p /tmp/.X11-unix \
  && chmod 1777 /tmp/.X11-unix \
  && mkdir -p /workspace/uploads /workspace/browser-shots /data/browser-profile \
  && chown -R user:user /workspace /data/browser-profile \
  && chmod 755 /workspace /data

WORKDIR /workspace

COPY requirements.txt /tmp/leagent-requirements.txt
RUN pip3 install --break-system-packages --no-cache-dir -r /tmp/leagent-requirements.txt \
  && rm -f /tmp/leagent-requirements.txt

COPY scripts/entrypoint-vnc.sh /entrypoint-vnc.sh
COPY scripts/entrypoint-multica-daemon.sh /entrypoint-multica-daemon.sh
COPY scripts/entrypoint-pi-web.sh /entrypoint-pi-web.sh
COPY scripts/cube-start.sh /usr/local/bin/cube-start.sh
COPY scripts/configure-pi-runtime.sh /usr/local/bin/configure-pi-runtime.sh
COPY scripts/configure-multica-runtime.sh /usr/local/bin/configure-multica-runtime.sh
COPY scripts/start-multica-runtime.sh /usr/local/bin/start-multica-runtime.sh
COPY scripts/register-s6-services.sh /usr/local/bin/register-s6-services.sh
COPY scripts/cont-init-browser.sh /etc/cont-init.d/99-browser-vnc
RUN chmod +x /entrypoint-vnc.sh \
  /entrypoint-multica-daemon.sh \
  /entrypoint-pi-web.sh \
  /usr/local/bin/cube-start.sh \
  /usr/local/bin/configure-pi-runtime.sh \
  /usr/local/bin/configure-multica-runtime.sh \
  /usr/local/bin/start-multica-runtime.sh \
  /usr/local/bin/register-s6-services.sh \
  /etc/cont-init.d/99-browser-vnc

COPY s6-playwright-vnc /etc/s6-overlay/s6-rc.d/playwright-vnc
COPY s6-multica-daemon /etc/s6-overlay/s6-rc.d/multica-daemon
COPY s6-pi-web /etc/s6-overlay/s6-rc.d/pi-web
RUN /usr/local/bin/register-s6-services.sh

# --- Multica CLI/daemon (GitHub Releases via official install script) ---
# MULTICA_INSTALL_CACHEBUST changes each build (see scripts/build.sh) so this
# layer is never reused from cache and always re-downloads the latest release.
ARG MULTICA_INSTALL_CACHEBUST=manual
RUN echo "multica install cachebust=${MULTICA_INSTALL_CACHEBUST}" \
  && curl -fsSL https://raw.githubusercontent.com/LRM-Teams/multica/main/scripts/install.sh \
    | MULTICA_BIN_DIR=/usr/local/bin bash \
  && chmod +x /usr/local/bin/multica \
  && multica version

# --- Pi CLI (baked at build time; provider credentials are injected at runtime) ---
ARG INSTALL_PI=1
ARG PI_SUITE_VERSION=0.1.17
ARG PI_SUITE=npm:@lebronj/pi-suite
ARG PI_WORKSPACE_DIR=/workspace
ARG PI_EVOLUTION_ENABLED=1
ARG NPM_REGISTRY=

USER user
ENV HOME=/home/user
ENV PATH="/home/user/.npm-global/bin:/home/user/.bun/bin:${PATH}"
WORKDIR /workspace

RUN mkdir -p /home/user/.npm-global \
  && npm config set prefix /home/user/.npm-global \
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
      mkdir -p "${HOME}/.pi/agent"; \
      PI_SUITE_SOURCE="${PI_SUITE}"; \
      if [ "${PI_SUITE}" = "npm:@lebronj/pi-suite" ] && [ -n "${PI_SUITE_VERSION}" ]; then \
        PI_SUITE_SOURCE="npm:@lebronj/pi-suite@${PI_SUITE_VERSION}"; \
      fi; \
      pi install "${PI_SUITE_SOURCE}"; \
      if command -v bun >/dev/null 2>&1; then \
        bun install -g https://github.com/tobi/qmd; \
        export PATH="${HOME}/.bun/bin:${PATH}"; \
        mkdir -p "${HOME}/.pi/agent/memory"; \
        if command -v qmd >/dev/null 2>&1; then \
          qmd collection add "${HOME}/.pi/agent/memory" --name pi-memory || true; \
          qmd embed || true; \
        fi; \
      else \
        echo "Bun not found. Core memory tools still work, but memory_search needs qmd."; \
      fi; \
    fi

USER root

RUN ln -sf /home/user/.npm-global/bin/pi /usr/local/bin/pi \
  && ln -sf /home/user/.npm-global/bin/pi-mcp-adapter /usr/local/bin/pi-mcp-adapter || true

COPY --chown=user:user pi-web /opt/pi-web

ENV PATH="/home/user/.npm-global/bin:/home/user/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/cube-start.sh"]

EXPOSE 5901 6079 6080 49983 49999
