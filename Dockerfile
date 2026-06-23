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

EXPOSE 5901 6080 49983 49999
