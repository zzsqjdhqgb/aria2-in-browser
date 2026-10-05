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
#   - an AgentTeams-ready web profile -> seeded into $DSH_HOME at start, see below
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
#   Both scripts are written further down in this file, not COPYed.
#
#   Restarts do no work: the provisioner compares the installed version with
#   DSH_PLUGIN_VERSION and stops when they match. On a new version, or with
#   DSH_PLUGIN_REFRESH=1, it installs -- offline first, because the build below
#   primes the pnpm store inside the image, then online. A failed install only
#   warns: the container still starts, with the volume's existing version.
#
#   The build still installs the plugin once, into a throwaway home: that pins
#   the dependency resolution, proves the pinned pair is installable, and warms
#   /root/.local/share/pnpm/store so the container's first start needs no
#   downloads.
#
# Runs as ROOT (uid 0) on purpose: there is no USER line, and both HOME and
# DSH_HOME live under /root. On a Linux host the files the container creates are
# therefore root-owned; on Windows/Docker Desktop the bind mount does not track
# ownership anyway.
#
# The dsh and plugin versions are pinned in the ARG block right below FROM (the
# only place either is specified).
# =============================================================================
FROM node:24-bookworm-slim

# Pinned versions -- the only places they are specified, and there is nothing to
# set in .env or docker-compose.yml. The defaults make the image identity fixed
# by this file alone.
#   DSH_VERSION: the harness CLI. Keep the plugin below compatible with it
#                (see the plugin's compatibility.json for the supported pairs).
#   AGENT_TEAMS_VERSION: @nanmicoder/dsh-agent-teams, the multi-agent team plugin
#                (captain + members + shared task DAG). Its roster cap is set in
#                the seeded cordis.patch.yml further down.
# Overridable at build time (docker-build.bat passes no build args, so both are
# the defaults unless the bat is edited -- a same-tag rebuild is then cache-hit).
ARG DSH_VERSION=0.2.0-rc.2
ARG AGENT_TEAMS_VERSION=0.1.22

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
# These ENV values are the whole image -> container contract; the provisioner
# reads them at start and has no other source of truth:
#   DSH_PLUGIN_VERSION  what "dsh plugin add" installs, and the version the
#                       provisioner compares the volume against.
#   DSH_PLUGIN_PATCH    the profile patch layer it applies when content differs.
#   DSH_SEED_PROFILES   which profile to provision (docker-*.bat use web).
# DSH_PLUGIN_HOME is build-only: the directory the scratch install below runs
# under, so it never touches /root/.dsh. It is deliberately not part of the
# runtime contract -- the provisioner works on $DSH_HOME only.
ENV DSH_PLUGIN_HOME=/opt/dsh-plugin \
    DSH_PLUGIN_VERSION="${AGENT_TEAMS_VERSION}" \
    DSH_PLUGIN_PATCH=/opt/dsh-plugin/cordis.patch.yml \
    DSH_SEED_PROFILES=web
RUN mkdir -p /root/.dsh/profiles /opt/dsh-plugin /root/.yarn/global /workspace

# Prime the plugin into the image, then hand the container only its config:
#   * DSH_HOME points at DSH_PLUGIN_HOME for this RUN only, so this scratch
#     install never lands in /root/.dsh -- which the dsh-home volume hides at
#     runtime, the trap this whole design avoids.
#   * No profile exists yet, so "dsh plugin" first initializes the shipped web
#     template (dsh-base + dsh-web-app) and then installs the plugin. This is
#     the same command the container runs at start, so the build proves the
#     pinned pair is installable and --save-exact keeps it a function of this
#     file rather than of whatever the registry resolves later.
#   * The scratch profile is deleted again on purpose: the image ships the
#     plugin's TARBALLS, warmed into /root/.local/share/pnpm/store (outside
#     every volume), not an installed profile. The container's install is then
#     an offline link step, and the volume keeps ownership of its profile.
#   * cordis.patch.yml is the image's profile configuration, mounted into the
#     volume by the provisioner: a 16-member roster cap, and reusable team
#     layouts any session starts with "/agent-teams --profile <name> <goal>".
#     Members inherit the captain's own model route, so no model is pinned.
RUN set -eux; \
    DSH_HOME="${DSH_PLUGIN_HOME}" dsh plugin --profile web add \
        --save-exact "@nanmicoder/dsh-agent-teams@${AGENT_TEAMS_VERSION}"; \
    test -d "${DSH_PLUGIN_HOME}/profiles/web/node_modules"; \
    rm -rf "${DSH_PLUGIN_HOME}/profiles"; \
    cat > "${DSH_PLUGIN_PATCH}" <<'YAML'
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
# and the warmed pnpm store lives under /root -- both plain image content, since
# nothing mounts over either path. Deliberately NOT a VOLUME or a compose mount:
# a volume there would be initialized empty and shadow it, the way dsh-home
# shadows everything under /root/.dsh.
#
# The entrypoint provisions $DSH_HOME's profile from the image, then execs the
# requested command. With the default CMD that is bash; the docker-*.bat files
# pass their own command after the image name, e.g.
# "dsh-dev:local bash /workspace/.env/sh/dsh.sh".
#
# Both scripts are written out here instead of COPYed from the build context.
# The context is the whole repository, and .env/ is a dot-directory inside it:
# on at least one Windows host the context walker did not deliver new files
# from .env/sh/, failing the build with "sh/... : not found". Rendering them
# keeps the image self-contained and independent of how the context is walked.
#
# The heredocs are quoted ('SH'), so nothing is expanded at build time. These
# bodies are the ONLY copy of the two scripts: there is no .env/sh/ twin to keep
# in sync. To test a change without a container, extract the body (everything
# between "cat > <path> <<'SH'" and the terminating "SH" line) into a file.
RUN set -eux; \
    cat > /usr/local/bin/dsh-profile-provision.sh <<'SH'
#!/usr/bin/env bash
# Provision the AgentTeams plugin into the container's DSH profile at start.
#
# Run by dsh-entrypoint.sh before the requested command, so it is the first
# thing that touches the profile and the last thing before dsh boots.
#
# WHY AT START AND NOT AT BUILD
#   $DSH_HOME (/root/.dsh) is a named volume. A named volume is filled from the
#   image only when it is FIRST created, and from then on it hides that whole
#   path -- so a build-time "dsh plugin add" into /root/.dsh reaches no
#   container, and a rebuilt image could never update an existing volume.
#   Installing here runs after the volume is mounted, so the result persists in
#   the volume exactly like a manual "dsh plugin --profile web add" would.
#
# WHAT IT DOES
#   1. If the profile's installed version already equals DSH_PLUGIN_VERSION,
#      nothing happens (no network, no writes) -- so ordinary restarts are fast
#      and work offline.
#   2. Otherwise it runs the official plugin command, which is a pnpm install:
#      offline first (a pnpm store warmed into the image answers that), then
#      online against the npm registry, and finally gives up with a warning --
#      the container still starts, just without the plugin.
#   3. The image's cordis.patch.yml is applied when its content differs, so
#      plugin configuration and team profiles change with the image.
#
# EMBEDDED IN THE IMAGE by .env/Dockerfile, which is the source of truth for
# what the container actually runs. The .env/sh/ copy is for testing.
#
# Usage: dsh-profile-provision.sh [profile]   (default: web)
set -euo pipefail

PROFILE="${1:-${DSH_SEED_PROFILES:-web}}"
VERSION="${DSH_PLUGIN_VERSION:-}"
PACKAGE="${DSH_PLUGIN_PACKAGE:-@nanmicoder/dsh-agent-teams}"
PATCH_SRC="${DSH_PLUGIN_PATCH:-/opt/dsh-plugin/cordis.patch.yml}"
DSH_HOME_DIR="${DSH_HOME:-/root/.dsh}"
PROFILE_DIR="$DSH_HOME_DIR/profiles/$PROFILE"
REFRESH="${DSH_PLUGIN_REFRESH:-}"

log() { printf 'dsh-provision: %s\n' "$*"; }
warn() { printf 'dsh-provision: WARNING: %s\n' "$*" >&2; }

# The version the volume currently has, straight from the installed manifest --
# the one source that cannot lie about what would actually be mounted.
installed_version() {
    local manifest="$PROFILE_DIR/node_modules/$PACKAGE/package.json"
    [[ -f "$manifest" ]] || return 0
    sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -1
}

# Offline first: the image warmed the pnpm store at build time, so the normal
# case is a few hundred milliseconds and no registry traffic. An upgrade the
# store does not have yet falls through to the online path.
install_plugin() {
    local log_file attempt args
    log_file="$(mktemp)"
    for attempt in offline online; do
        args=(plugin --profile "$PROFILE" add --save-exact)
        [[ "$attempt" == "offline" ]] && args+=(--offline)
        log "installing $PACKAGE@$VERSION into profile $PROFILE ($attempt)"
        if timeout "${DSH_PLUGIN_TIMEOUT:-600}" dsh "${args[@]}" "$PACKAGE@$VERSION" \
            >"$log_file" 2>&1; then
            tail -3 "$log_file"
            rm -f "$log_file"
            return 0
        fi
        [[ "$attempt" == "offline" ]] &&
            log "not in the local store; retrying online (needs the npm registry)"
    done
    warn "install failed; full log follows"
    sed 's/^/dsh-provision:   /' "$log_file" >&2
    rm -f "$log_file"
    return 1
}

apply_patch_layer() {
    local dest="$PROFILE_DIR/cordis.patch.yml"
    [[ -f "$PATCH_SRC" ]] || return 0
    if [[ -f "$dest" ]] && cmp -s "$PATCH_SRC" "$dest"; then
        return 0
    fi
    mkdir -p "$PROFILE_DIR"
    cp "$PATCH_SRC" "$dest"
    log "applied the image's $PROFILE/cordis.patch.yml"
}

if [[ -z "$VERSION" ]]; then
    warn "DSH_PLUGIN_VERSION is empty -- skipping the plugin install"
    exit 0
fi

if ! mkdir -p "$DSH_HOME_DIR/profiles"; then
    warn "cannot create $DSH_HOME_DIR/profiles -- skipping the plugin install"
    exit 0
fi

current="$(installed_version)"
if [[ "$current" == "$VERSION" && "$REFRESH" != "1" ]]; then
    log "$PACKAGE@$current already installed (set DSH_PLUGIN_REFRESH=1 to reinstall)"
else
    [[ "$REFRESH" == "1" && "$current" == "$VERSION" ]] && log "reinstalling on DSH_PLUGIN_REFRESH=1"
    [[ -n "$current" && "$current" != "$VERSION" ]] &&
        log "upgrading $PACKAGE from $current to $VERSION"
    if ! install_plugin; then
        if [[ -n "$current" ]]; then
            warn "keeping $PACKAGE@$current from the volume; the container still starts"
        else
            warn "the container starts without $PACKAGE"
        fi
    fi
fi

apply_patch_layer
SH
RUN set -eux; \
    cat > /usr/local/bin/dsh-entrypoint.sh <<'SH'
#!/usr/bin/env bash
# Container entrypoint: provision the image's plugins into the DSH profile,
# then run the requested command unchanged.
#
# The provisioning work lives in dsh-profile-provision.sh so it can be
# exercised on its own (see the plugin section in .env/README.md).
#
# `exec "$@"` keeps the container's command in charge -- signals, exit codes and
# TTY behaviour are exactly as if no entrypoint were present. With the image's
# default CMD that is "bash"; docker-*.bat pass e.g.
# "bash /workspace/.env/sh/dsh.sh".
#
# EMBEDDED IN THE IMAGE by .env/Dockerfile, which is the source of truth for
# what the container actually runs. The .env/sh/ copy is for testing.
set -euo pipefail

here="$(dirname "$(readlink -f "$0")")"
if [[ -x "$here/dsh-profile-provision.sh" ]]; then
    "$here/dsh-profile-provision.sh" "${DSH_SEED_PROFILES:-web}" || true
else
    printf 'dsh-entrypoint: WARNING: %s is missing; starting without provisioning plugins\n' \
        "$here/dsh-profile-provision.sh" >&2
fi

exec "$@"
SH
# The seed profile is gone by now; this is the only thing the build stages into
# /opt/dsh-plugin for runtime, so fail loudly if the earlier step lost it.
RUN set -eux; \
    test -f "${DSH_PLUGIN_PATCH}"; \
    chmod 0755 /usr/local/bin/dsh-entrypoint.sh /usr/local/bin/dsh-profile-provision.sh
ENTRYPOINT ["dsh-entrypoint.sh"]

# Runs as root: no USER line, so the container is uid 0 by default.
# Kept as CMD (not an argument to ENTRYPOINT) so every docker-*.bat keeps
# working unchanged: "docker run <image> <cmd>" still overrides exactly this.
CMD ["bash"]
