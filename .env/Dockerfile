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
#   - two scripts    -> the entrypoint and the plugin provisioner (see below);
#                       the provisioner owns the plugin list, so this image
#                       names no plugin and needs no rebuild to change one
#
# The project is bind-mounted at runtime; install its dependencies yourself from
# inside the container with "yarn install" when you need them.
#
# WHERE THE PROFILE COMES FROM (installed at container start, not at build)
#   $DSH_HOME is the named volume dsh-home. A named volume is filled from the
#   image only when it is FIRST created; after that it hides that whole path.
#   So a build-time "dsh plugin add" into /root/.dsh would reach no container,
#   and a rebuilt image could never update an existing volume.
#
#   The install therefore runs at container start, after the volume is mounted:
#   the image's ENTRYPOINT (dsh-entrypoint.sh) calls dsh-profile-provision.sh,
#   which runs the official "dsh plugin --profile web add" into $DSH_HOME. The
#   result persists in the volume exactly like a manual install would.
#   Both scripts live in .env/sh/ and are COPYed in at the end of this file.
#
#   Restarts are NOT free, deliberately: dsh-profile-provision.sh installs its
#   own plugin list -- whose entries end in @latest -- at every container start,
#   so the profile tracks whatever was published since the last start. That list
#   lives in the script, which is bind-mounted: editing it costs a container
#   restart, not a rebuild, and this image knows no plugin name at all. A failed
#   install only warns: the container still starts, with whatever the volume
#   already has.
#
# Runs as ROOT (uid 0) on purpose: there is no USER line, and both HOME and
# DSH_HOME live under /root. On a Linux host the files the container creates are
# therefore root-owned; on Windows/Docker Desktop the bind mount does not track
# ownership anyway.
#
# The dsh version is pinned in the ARG block right below FROM (the only place it
# is specified); plugin versions are not pinned anywhere.
# =============================================================================
FROM node:24-bookworm-slim

# Pinned harness version -- the only place it is specified; there is nothing to
# set in .env or docker-compose.yml, so the image identity is fixed by this file
# alone. Every plugin below must stay compatible with it (the installer's gate
# only checks @deepseek-ai/dsh* peerDependencies -- no `compatibility` field).
# Overridable at build time; docker-build.bat passes no build args, so this is
# the default unless the bat is edited (a same-tag rebuild is then a cache hit).
ARG DSH_VERSION=0.2.0-rc.2

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
# dsh version: pinned in the ARG block at the top of this file.
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

# yarn 4 keeps its cache inside the project (.yarn/) by default, which would land
# on the Windows host through the bind mount and be slow. Point the global cache
# (and the Corepack download cache, which lives under the home directory) at
# /root instead.
RUN printf 'globalFolder: /root/.yarn/global\nenableTelemetry: false\n' > /root/.yarnrc.yml

# Pre-create the directories that named volumes are mounted on: a volume inherits
# the directory and its ownership from the image on first creation.
#
# The plugin list is NOT here: dsh-profile-provision.sh owns it, because that
# script is bind-mounted and can be edited by restarting the container. This
# image only carries what the plugins must be configured with -- the patch layer
# below -- and the two scripts that do the work.
#
# DSH_PLUGIN_PATCH    the profile patch layer the provisioner seeds into the volume.
# DSH_SEED_PROFILES   which profile to provision (docker-*.bat use web).
ENV DSH_PLUGIN_PATCH=/opt/dsh-plugin/cordis.patch.yml \
    DSH_SEED_PROFILES=web
RUN mkdir -p /root/.dsh/profiles /opt/dsh-plugin /root/.yarn/global /workspace

# The image's profile configuration, mounted into the volume by the provisioner:
# a 16-member roster cap, and reusable team layouts any session starts with
# "/agent-teams --profile <name> <goal>". Members inherit the captain's own model
# route, so no model is pinned. dsh-boot-animation needs no row here: its own
# package manifest declares dsh.bundle.patch, which "dsh plugin add" reconciles
# into the profile's bundle list on install.
#
# Its own RUN, containing nothing but the heredoc: when this logic shared a RUN
# with other commands, the Docker parser never found the heredoc and read the
# YAML as instructions ("unknown instruction: -").
RUN cat > "${DSH_PLUGIN_PATCH}" <<'YAML'
# Profile patch layer for the container's web profile, mounted into the volume
# by dsh-profile-provision.sh. Owned by .env/Dockerfile: change it here
# and rebuild, rather than editing the copy inside a running container (a
# differing copy is overwritten on the next start).
- id: agent-teams
  name: "@nanmicoder/dsh-agent-teams"
  config:
    # Roster cap. The plugin defaults to 8; one delivery already needs an
    # implementer plus a verifier and a reviewer, so 8 strands parallel work.
    # Idle roster rows issue no model requests, so the cap itself is free.
    maxMembers: 16
    # Reusable team layouts: /agent-teams --profile feature-delivery <goal>
    profiles:
      feature-delivery:
        description: Requirements, implementation, verification and review for one feature
        protocol: Agree the requirements before any implementation, verify with real commands, review a different member's work, and never deploy.
        members:
          - name: analyst
            role: Turn the goal into testable requirements and explicit acceptance criteria
          - name: implementer
            role: Implement the approved requirements with the smallest correct change
          - name: verifier
            role: Independently run the verification commands and report raw evidence
          - name: reviewer
            role: Review the delivered diff against the requirements and either pass or list findings
        tasks:
          - id: requirements
            subject: Requirements and acceptance criteria
            assignee: analyst
          - id: implementation
            subject: Implement the approved change
            assignee: implementer
            dependencies: [requirements]
          - id: verification
            subject: Independent verification
            assignee: verifier
            dependencies: [implementation]
          - id: review
            subject: Adversarial review of the delivered change
            assignee: reviewer
            dependencies: [implementation]
      audit:
        description: Parallel investigation of one question from independent angles
        protocol: Each member investigates independently, cites file and line evidence, and never edits files.
        members:
          - name: code-reader
            role: Read the implementation and report how it actually behaves
          - name: history-reader
            role: Read git history and report when and why the current state changed
          - name: risk-reader
            role: Look for failure modes, security and data-loss risks
        tasks:
          - id: code
            subject: How the code actually behaves
            assignee: code-reader
          - id: history
            subject: When and why it changed
            assignee: history-reader
          - id: risks
            subject: Failure modes and risks
            assignee: risk-reader
YAML

# Trust the bind-mounted workspace for git. Running as root against a root-owned
# mount already passes git's ownership check, so this is a no-op there; it keeps
# git usable when the mount carries a different uid instead (Linux host, or a
# Docker Desktop mapping that is not root). --system stores it in /etc/gitconfig,
# i.e. in the image, so it survives container recreation - a ~/.gitconfig would
# not, since /root itself is not a volume.
RUN git config --system --add safe.directory /workspace

WORKDIR /workspace

# /opt/dsh-plugin holds only the image's profile configuration (the patch layer)
# -- plain image content, since nothing mounts over that path. Deliberately NOT a
# VOLUME or a compose mount: a volume there would be initialized empty and shadow
# it, the way dsh-home shadows everything under /root/.dsh.
#
# The entrypoint provisions $DSH_HOME's profile, then execs the requested
# command. With the default CMD that is bash; the docker-*.bat files pass their
# own command after the image name, e.g.
# "dsh-dev:local bash /workspace/.env/sh/dsh.sh".
#
# Both scripts live in .env/sh/ as ordinary files so they can be syntax-checked
# and run outside a build. The mode is set explicitly below, because a Windows
# checkout may not carry it in the context.
#
# The source path is relative to the BUILD CONTEXT, which docker-compose.yml
# sets to the repository root ("context: .."). The scripts are at
# <repo>/.env/sh/, so inside the context they are ".env/sh/<name>" -- the ".env/"
# prefix is part of the path and must not be dropped.
COPY .env/sh/dsh-entrypoint.sh .env/sh/dsh-profile-provision.sh /usr/local/bin/
RUN set -eux; \
    test -f "${DSH_PLUGIN_PATCH}"; \
    chmod 0755 /usr/local/bin/dsh-entrypoint.sh /usr/local/bin/dsh-profile-provision.sh
ENTRYPOINT ["dsh-entrypoint.sh"]

# Runs as root: no USER line, so the container is uid 0 by default.
# Kept as CMD (not an argument to ENTRYPOINT) so every docker-*.bat keeps
# working unchanged: "docker run <image> <cmd>" still overrides exactly this.
CMD ["bash"]
