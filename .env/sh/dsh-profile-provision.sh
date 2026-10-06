#!/usr/bin/env bash
# Provision the image's DSH plugins into the container's profile at start.
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
#   1. Installs the list below at EVERY start. Nothing is pinned: the entries
#      end in @latest, so a restart picks up whatever was published since the
#      last one (and an unchanged one just costs a resolution round-trip).
#   2. Two batches, because they need different commands -- and so a github
#      outage cannot take the registry plugins down with it:
#        registry specs  "add --save-exact <spec>"  pnpm re-resolves @latest
#        git specs       "add <spec>" then "update <name>"  (see below)
#   3. Fails soft: a failed install only warns, and the container starts with
#      whatever the volume already has.
#   4. The image's cordis.patch.yml is seeded when the live file has no rows.
#
# WHY GIT SPECS NEED TWO COMMANDS
#   pnpm has no @latest for a git dependency: it resolves the ref once and
#   records the commit in the lockfile, after which a plain "add" keeps that
#   commit -- verified: even "add --force" re-fetches the locked commit instead
#   of re-resolving the ref. Only "update <name>" re-resolves it, so a git entry
#   is added (installs it, or proves it is there) and then updated by name.
#
# Lives in .env/sh/ and is COPYed into the image at /usr/local/bin/ by
# .env/Dockerfile. Keep it LF-only: .env/.gitattributes enforces that, and bash
# rejects a shebang or command ending in a stray carriage return.
#
# Usage: dsh-profile-provision.sh [profile]   (default: web)
set -euo pipefail

PROFILE="${1:-${DSH_SEED_PROFILES:-web}}"

# THE PLUGIN LIST -- this file is its home, and the only place it lives. It is
# not in the Dockerfile and not in a generated file: .env/sh/ is bind-mounted
# into the container, so editing the list here and restarting the container is
# the whole change. No image rebuild, and the image stays plugin-agnostic.
#   <name>@latest            registry package, re-resolved at every start
#   github:<owner>/<repo>    not on npm; installed, then updated by name
# DSH_PLUGIN_SPECS overrides the list for one container (compose injects .env
# through env_file); that is the only other place a list can come from.
PLUGIN_SPECS="${DSH_PLUGIN_SPECS:-@nanmicoder/dsh-agent-teams@latest dsh-better-sidebar@latest dsh-context@latest dsh-whale-widget@latest github:NativeDog1/dsh-boot-animation}"
PATCH_SRC="${DSH_PLUGIN_PATCH:-/opt/dsh-plugin/cordis.patch.yml}"
DSH_HOME_DIR="${DSH_HOME:-/root/.dsh}"
PROFILE_DIR="$DSH_HOME_DIR/profiles/$PROFILE"

# pnpm's store, kept in $DSH_HOME on purpose. Only /root/.dsh is a volume: the
# default store (~/.local/share/pnpm/store) lives in the container's writable
# layer, so every new container would re-download every tarball -- hundreds of
# MB per start, for plugins the volume already has. Here it sits next to the
# profile it serves, survives container recreation like the profile does, and
# shares a filesystem with node_modules so pnpm can hard-link instead of copy.
STORE_DIR="$DSH_HOME_DIR/.pnpm-store"

log() { printf 'dsh-provision: %s\n' "$*"; }
warn() { printf 'dsh-provision: WARNING: %s\n' "$*" >&2; }

# Online first: resolving @latest is the whole point, and only the online path
# can see a release published since the last start. The offline retry is there
# for a start with no network: the lockfile the volume already has then answers
# the command, so a container with no network still boots on its current plugins.
install_specs() {
    local log_file attempt args
    log_file="$(mktemp)"
    for attempt in online offline; do
        args=(plugin --profile "$PROFILE" add --save-exact "--store-dir=$STORE_DIR")
        [[ "$attempt" == "offline" ]] && args+=(--offline)
        log "installing into profile $PROFILE ($attempt): $*"
        if timeout "${DSH_PLUGIN_TIMEOUT:-600}" dsh "${args[@]}" "$@" \
            >"$log_file" 2>&1; then
            tail -3 "$log_file"
            rm -f "$log_file"
            return 0
        fi
        [[ "$attempt" == "online" ]] &&
            log "install failed; retrying offline against the volume's own lockfile"
    done
    warn "install failed; full log follows"
    sed 's/^/dsh-provision:   /' "$log_file" >&2
    rm -f "$log_file"
    return 1
}

# The package name a git spec installs, for "update": the last path segment of
# github:owner/repo or git+https://host/owner/repo.git, without its #ref or .git.
spec_name() {
    local spec="${1%%#*}"
    spec="${spec##*/}"
    printf '%s\n' "${spec%.git}"
}

# Re-resolve a git spec's ref and install whatever it now points at. update has
# nothing to offer offline, so this is one online attempt.
update_spec() {
    local log_file
    log_file="$(mktemp)"
    log "updating $1 (git spec: re-resolving its ref)"
    if timeout "${DSH_PLUGIN_TIMEOUT:-600}" dsh plugin --profile "$PROFILE" update "--store-dir=$STORE_DIR" "$1" \
        >"$log_file" 2>&1; then
        tail -2 "$log_file"
        rm -f "$log_file"
        return 0
    fi
    warn "update failed for $1"
    sed 's/^/dsh-provision:   /' "$log_file" >&2
    rm -f "$log_file"
    return 1
}

# Never silently discard configuration the container owns. The live file is
# written by two parties: this image (defaults) and the Web UI config editor
# (user changes) -- and the editor rewrites the whole document, reformatting
# lines and appending rows for other plugins. A byte comparison therefore
# reports "different" for any user edit and would overwrite it.
#
# The guard is per-row instead: every row this image owns (matched by its
# "id:", the key the patch layer composes on) must already be present in the
# live file. If so, the image has nothing to add and the file is left alone --
# user edits, reformatted YAML and extra rows all survive.
#
# Additions are reported rather than applied. Set DSH_PLUGIN_FORCE_PATCH=1 to
# apply the image copy regardless, or delete the live file to re-seed it.
image_row_ids() {
    sed -n 's/^[[:space:]]*-[[:space:]]*id:[[:space:]]*\(.*\)$/\1/p' "$PATCH_SRC" |
        sed 's/^["'"'"']//; s/["'"'"']$//'
}

apply_patch_layer() {
    local dest="$PROFILE_DIR/cordis.patch.yml"
    [[ -f "$PATCH_SRC" ]] || return 0
    mkdir -p "$PROFILE_DIR"

    if [[ ! -f "$dest" ]]; then
        cp "$PATCH_SRC" "$dest"
        log "seeded $PROFILE/cordis.patch.yml from the image"
        return 0
    fi

    # A freshly initialized profile carries the template's empty patch ("[]\n",
    # or comments only). That is not user content, so seed over it -- otherwise
    # a new container would keep an empty patch and never get the image
    # defaults. Parse-free test: strip comments, whitespace and the empty-flow
    # markers; anything left means someone wrote real rows.
    if [[ -z "$(sed 's/#.*$//' "$dest" | tr -d '[:space:][]' )" ]]; then
        cp "$PATCH_SRC" "$dest"
        log "seeded $PROFILE/cordis.patch.yml from the image (live file held no rows)"
        return 0
    fi

    local id missing=0
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if ! grep -qE "^[[:space:]]*-[[:space:]]*id:[[:space:]]*[\"']?${id}[\"']?[[:space:]]*$" "$dest"; then
            warn "the image's $PROFILE/cordis.patch.yml declares row \"$id\", which the live file does not have"
            missing=1
        fi
    done < <(image_row_ids)

    if [[ "$missing" == "0" ]]; then
        return 0
    fi

    if [[ "${DSH_PLUGIN_FORCE_PATCH:-}" == "1" ]]; then
        warn "DSH_PLUGIN_FORCE_PATCH=1 -- replacing $dest with the image copy"
        cp "$PATCH_SRC" "$dest"
        return 0
    fi
    warn "keeping the live file (it carries your own settings); set DSH_PLUGIN_FORCE_PATCH=1 to apply the image copy"
    return 0
}

if [[ -z "${PLUGIN_SPECS// /}" ]]; then
    warn "no plugin specs: the built-in list is empty and DSH_PLUGIN_SPECS was overridden to nothing"
    exit 0
fi

if ! mkdir -p "$DSH_HOME_DIR/profiles"; then
    warn "cannot create $DSH_HOME_DIR/profiles -- skipping the plugin install"
    exit 0
fi

# Split the list by where each entry comes from. A git entry names its own
# source, so it is the only kind that needs the "add then update" pair above; a
# registry entry is handed to pnpm as-is, @latest included.
registry=()
sourced=()
for spec in $PLUGIN_SPECS; do
    case "$spec" in
        github:* | git+* | *.git | *.git#*) sourced+=("$spec") ;;
        *) registry+=("$spec") ;;
    esac
done

failed=0
if (( ${#registry[@]} > 0 )); then
    install_specs "${registry[@]}" || failed=1
fi
if (( ${#sourced[@]} > 0 )); then
    install_specs "${sourced[@]}" || failed=1
    for spec in "${sourced[@]}"; do
        update_spec "$(spec_name "$spec")" || failed=1
    done
fi
if (( failed != 0 )); then
    warn "the container still starts, with whatever the volume already has"
fi

apply_patch_layer
