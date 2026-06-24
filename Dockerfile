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
COPY scripts/register-s6-services.sh /usr/local/bin/register-s6-services.sh
COPY scripts/cont-init-browser.sh /etc/cont-init.d/99-browser-vnc
RUN chmod +x /entrypoint-vnc.sh \
  /usr/local/bin/register-s6-services.sh \
  /etc/cont-init.d/99-browser-vnc

COPY s6-playwright-vnc /etc/s6-overlay/s6-rc.d/playwright-vnc
RUN /usr/local/bin/register-s6-services.sh

# --- Pi CLI (baked at build time; requires TEAM_API_KEY via build-arg) ---
ARG INSTALL_PI=1
ARG TEAM_API_KEY
ARG TEAM_BASE_URL=https://claude-code.club/openai/v1
ARG TEAM_MODEL=gpt-5.5
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
    elif [ -z "${TEAM_API_KEY}" ]; then \
      echo "TEAM_API_KEY is required when INSTALL_PI=1" >&2; exit 1; \
    else \
      if [ -n "${NPM_REGISTRY}" ]; then \
        npm config set registry "${NPM_REGISTRY}"; \
        echo "Using npm registry: ${NPM_REGISTRY}"; \
      fi; \
      export TEAM_API_KEY="${TEAM_API_KEY}" \
        TEAM_BASE_URL="${TEAM_BASE_URL}" \
        TEAM_MODEL="${TEAM_MODEL}" \
        PI_SUITE="${PI_SUITE}" \
        PI_WORKSPACE_DIR="${PI_WORKSPACE_DIR}" \
        PI_EVOLUTION_ENABLED="${PI_EVOLUTION_ENABLED}"; \
      ok=0; \
      for attempt in 1 2 3; do \
        echo "Pi bootstrap attempt ${attempt}/3..."; \
        if curl -fsSL "https://registry.npmjs.org/@lebronj/pi-suite/-/pi-suite-${PI_SUITE_VERSION}.tgz" \
          | tar -xzO package/scripts/bootstrap.sh | bash; then \
          ok=1; \
          break; \
        fi; \
        echo "Pi bootstrap attempt ${attempt} failed, retrying..." >&2; \
        sleep 15; \
      done; \
      if [ "${ok}" != "1" ]; then \
        echo "Pi bootstrap failed after 3 attempts" >&2; \
        exit 1; \
      fi; \
    fi

USER root

EXPOSE 5901 6080 49983 49999
