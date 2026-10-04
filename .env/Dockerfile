# =============================================================================
# DSH (DeepSeek Harness) development image
#
# Location: <repo>/.env/Dockerfile
#   build context = repository root (docker-build.bat passes "%~dp0..")
#
# Scope: this image provides the tools only. It deliberately does NOT touch the
# project: no project files are copied in, and no project command (yarn install,
# postinstall, wxt prepare, build, test) runs at build time. Nothing from this
# repository is executed while building the image.
#
# Contents:
#   - Node.js 24 (dsh is published with 24.x)
#   - dsh CLI        -> npm package @deepseek-ai/dsh, bin name "dsh"
#   - dev toolchain  -> git / ripgrep / python3 / make / g++ for the agent and node-gyp
#   - pnpm + yarn 4  -> dsh plugin management and this project (yarn@4.17.1)
#
# The project is bind-mounted at runtime; install its dependencies yourself from
# inside the container with "yarn install" when you need them.
#
# Change the dsh version by editing ARG DSH_VERSION below, or with
# docker build --build-arg DSH_VERSION=<version|dist-tag>.
# =============================================================================
FROM node:24-bookworm-slim

ARG DSH_VERSION=0.2.0-rc.2

ENV DEBIAN_FRONTEND=noninteractive \
    DSH_HOME=/home/dsh/.dsh \
    DSH_WORKSPACE=/workspace \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Shanghai \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

# git/ripgrep serve the agent's search and version-control tools;
# python3/make/g++ cover node-gyp style native dependencies.
# socat backs .env/sh/dsh.sh: "dsh web" refuses to bind anything but loopback
# (--host 0.0.0.0 is a usage error), so publishing its port to the host needs a
# relay that listens on 0.0.0.0 and forwards to it.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        ripgrep \
        socat \
        less \
        jq \
        procps \
        python3 \
        make \
        g++ \
    ; \
    rm -rf /var/lib/apt/lists/*

# Install the dsh CLI (global, so "dsh" works directly inside the container;
# running it via npx @deepseek-ai/dsh is equally supported)
RUN set -eux; \
    npm install -g "@deepseek-ai/dsh@${DSH_VERSION}"; \
    command -v dsh; \
    dsh --version

# pnpm backs "dsh plugin --profile <name> add ..."; yarn 4 is this project's package manager
RUN set -eux; \
    npm install -g pnpm; \
    corepack enable; \
    corepack prepare yarn@4.17.1 --activate; \
    pnpm --version; \
    yarn --version

# Non-root user (uid 1000). To run as root instead: drop the USER line below and
# replace /home/dsh with /root throughout.
RUN set -eux; \
    usermod -l dsh -d /home/dsh -m node; \
    groupmod -n dsh node; \
    mkdir -p /home/dsh/.dsh /home/dsh/.yarn/global /workspace; \
    chown -R dsh:dsh /home/dsh /workspace

# yarn 4 keeps its cache inside the project (.yarn/) by default, which would land
# on the Windows host through the bind mount and be slow. Point the global cache
# (and the Corepack download cache, which lives under ~/.cache) at the container
# home directory instead.
RUN printf 'globalFolder: /home/dsh/.yarn/global\nenableTelemetry: false\n' > /home/dsh/.yarnrc.yml \
    && chown dsh:dsh /home/dsh/.yarnrc.yml

# Pre-create $DSH_HOME/profiles: a named volume inherits the directory and its
# ownership from the image on first creation, so a root-owned .dsh cannot appear
RUN mkdir -p /home/dsh/.dsh/profiles && chown -R dsh:dsh /home/dsh/.dsh

USER dsh
WORKDIR /workspace

# Default = plain bash. The docker-*.bat files pass their own command after the
# image name, e.g. "dsh-dev:local bash /workspace/.env/sh/dsh.sh" for the Web UI.
CMD ["bash"]
