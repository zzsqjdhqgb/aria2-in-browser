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
# Runs as ROOT (uid 0) on purpose: there is no USER line, and both HOME and
# DSH_HOME live under /root. On a Linux host the files the container creates are
# therefore root-owned; on Windows/Docker Desktop the bind mount does not track
# ownership anyway.
#
# The dsh version is pinned in the npm install line below (the only place it is
# specified - there is no build arg and no entry in .env or docker-compose.yml).
# =============================================================================
FROM node:24-bookworm-slim

# GIT_OPTIONAL_LOCKS=0: .git is bind-mounted read-only, so git must not attempt
# its optional index refresh/write. Without this, status/diff still work, but
# they rely on git silently tolerating the failed write.
ENV DEBIAN_FRONTEND=noninteractive \
    DSH_HOME=/root/.dsh \
    DSH_WORKSPACE=/workspace \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Shanghai \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    GIT_OPTIONAL_LOCKS=0 \
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
# running it via npx @deepseek-ai/dsh is equally supported).
# dsh version: pinned here, change it on this line only.
RUN set -eux; \
    npm install -g "@deepseek-ai/dsh@0.2.0-rc.2"; \
    command -v dsh; \
    dsh --version

# pnpm backs "dsh plugin --profile <name> add ..."; yarn 4 is this project's package manager
RUN set -eux; \
    npm install -g pnpm; \
    corepack enable; \
    corepack prepare yarn@4.17.1 --activate; \
    pnpm --version; \
    yarn --version

# yarn 4 keeps its cache inside the project (.yarn/) by default, which would land
# on the Windows host through the bind mount and be slow. Point the global cache
# (and the Corepack download cache, which lives under the home directory) at
# /root instead.
RUN printf 'globalFolder: /root/.yarn/global\nenableTelemetry: false\n' > /root/.yarnrc.yml

# Pre-create the directories that named volumes are mounted on: a volume inherits
# the directory and its ownership from the image on first creation.
RUN mkdir -p /root/.dsh/profiles /root/.yarn/global /workspace

# Trust the bind-mounted workspace for git. Running as root against a root-owned
# mount already passes git's ownership check, so this is a no-op there; it keeps
# git usable when the mount carries a different uid instead (Linux host, or a
# Docker Desktop mapping that is not root). --system stores it in /etc/gitconfig,
# i.e. in the image, so it survives container recreation - a ~/.gitconfig would
# not, since /root itself is not a volume.
RUN git config --system --add safe.directory /workspace

WORKDIR /workspace

# Runs as root: no USER line, so the container is uid 0 by default.
# Default command = plain bash; the docker-*.bat files pass their own command
# after the image name, e.g. "dsh-dev:local bash /workspace/.env/sh/dsh.sh".
CMD ["bash"]
