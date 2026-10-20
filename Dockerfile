# Staging Swarm computer image. The host starts this image with no command, so
# the entrypoint is `coforge-computer foreground`. The host injects the binding
# environment; this image does not run `setup --workspace`.
# Pi, DeepSeek, and the Lenovo CA stay in the image. The local web terminal
# remains available via cube-start.sh, which compose overrides to.

ARG SANDBOX_IMAGE=cube-sandbox-cn.tencentcloudcr.com/cube-sandbox/sandbox-code@sha256:b551b169de85c0216cce9453a8e22059ca47fd3dceced75e918cf1c8de60464b
FROM ${SANDBOX_IMAGE}

ARG NODE_MAJOR=22
ARG INSTALL_PI=1
ARG PI_SUITE_VERSION=0.1.17
ARG PI_SUITE=npm:@lebronj/pi-suite
ARG PI_WORKSPACE_DIR=/workspace
ARG PI_EVOLUTION_ENABLED=1
ARG NPM_REGISTRY=
# Debian apt mirror (empty = keep image default sources). China default: Aliyun.
ARG APT_MIRROR=https://mirrors.aliyun.com/debian
ARG APT_SECURITY_MIRROR=https://mirrors.aliyun.com/debian-security
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

# Terminal toolkit plus Node for Pi and the web terminal. No browser or desktop stack.
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
COPY scripts/entrypoint-pi-web.sh /entrypoint-pi-web.sh
COPY scripts/entrypoint-coforge-daemon.sh /entrypoint-coforge-daemon.sh
COPY scripts/cube-start.sh /usr/local/bin/cube-start.sh
COPY scripts/configure-pi-runtime.sh /usr/local/bin/configure-pi-runtime.sh
COPY scripts/bake-pi-deepseek.sh /usr/local/bin/bake-pi-deepseek.sh
COPY scripts/container-systemctl /usr/local/bin/systemctl
COPY config/pi-modelfactory-provider.json /usr/local/share/coforge/pi-modelfactory-provider.json
RUN chmod 755 /usr/local/bin/coforge-computer \
    /entrypoint-pi-web.sh \
    /entrypoint-coforge-daemon.sh \
  /usr/local/bin/cube-start.sh \
  /usr/local/bin/configure-pi-runtime.sh \
  /usr/local/bin/bake-pi-deepseek.sh \
  /usr/local/bin/systemctl

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

# Bake Lenovo ModelFactory DeepSeek into the image so `pi` works without runtime secret injection.
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
      grep -q 'https://modelfactory.lenovo.com/llm/v1' /root/.pi/agent/models.json; \
      grep -q '"id": "DeepSeek"' /root/.pi/agent/models.json; \
      grep -q '"defaultModel": "DeepSeek"' /root/.pi/agent/settings.json; \
    fi

# Web terminal native deps. node_modules survives the later COPY (context excludes it).
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

RUN printf '%s\n' '#!/bin/sh' 'exec /usr/local/bin/coforge-computer __agent-cli "$@"' \
      > /usr/local/bin/coforge \
  && chmod 755 /usr/local/bin/coforge

# This machine's working Pi setup. Gitignored; absent in other checkouts, so the
# baked DeepSeek config stays. Present here, it is what cloud Agents chat with.
COPY config/pi-agent/ /tmp/pi-agent/
RUN if [ -f /tmp/pi-agent/models.json ]; then \
      cp /tmp/pi-agent/models.json /root/.pi/agent/models.json; \
      if [ -f /tmp/pi-agent/settings.json ]; then cp /tmp/pi-agent/settings.json /root/.pi/agent/settings.json; fi; \
      mkdir -p /root/.pi/agent/certs; \
      if [ -d /tmp/pi-agent/certs ]; then cp -a /tmp/pi-agent/certs/. /root/.pi/agent/certs/; fi; \
      chmod 600 /root/.pi/agent/models.json; \
      chmod 644 /root/.pi/agent/certs/* 2>/dev/null || true; \
    fi; \
    rm -rf /tmp/pi-agent

COPY scripts/entrypoint-foreground.sh /usr/local/bin/entrypoint-foreground.sh
RUN chmod 755 /usr/local/bin/entrypoint-foreground.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint-foreground.sh"]

EXPOSE 6079
