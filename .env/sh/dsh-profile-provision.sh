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
#   1. If every spec in DSH_PLUGIN_SPECS is already installed at the pinned
#      version, nothing happens (no network, no writes) -- so ordinary restarts
#      are fast and work offline.
#   2. Otherwise it runs the official plugin command, which is a pnpm install:
#      offline first (a pnpm store warmed into the image answers that), then
#      online against the npm registry, and finally gives up with a warning --
#      the container still starts, just without the plugin.
#   3. The image's cordis.patch.yml is applied when its content differs, so
#      plugin configuration and team profiles change with the image.
#
# Lives in .env/sh/ and is COPYed into the image at /usr/local/bin/ by
# .env/Dockerfile. Keep it LF-only: .env/.gitattributes enforces that, and bash
# rejects a shebang or command ending in a stray carriage return.
#
# Usage: dsh-profile-provision.sh [profile]   (default: web)
set -euo pipefail

PROFILE="${1:-${DSH_SEED_PROFILES:-web}}"
# No built-in default list on purpose: entrypoint loads the versions this image
# resolved from @latest (specs.env) and exports DSH_PLUGIN_SPECS. Running this
# script by hand without setting anything must not install some arbitrary
# unpinned package, so it stops instead. DSH_PLUGIN_PACKAGE is the explicit
# single-package escape hatch.
PLUGIN_SPECS="${DSH_PLUGIN_SPECS:-}"
[[ -n "${DSH_PLUGIN_PACKAGE:-}" ]] && PLUGIN_SPECS="$DSH_PLUGIN_PACKAGE"
PATCH_SRC="${DSH_PLUGIN_PATCH:-/opt/dsh-plugin/cordis.patch.yml}"
DSH_HOME_DIR="${DSH_HOME:-/root/.dsh}"
PROFILE_DIR="$DSH_HOME_DIR/profiles/$PROFILE"
REFRESH="${DSH_PLUGIN_REFRESH:-}"

log() { printf 'dsh-provision: %s\n' "$*"; }
warn() { printf 'dsh-provision: WARNING: %s\n' "$*" >&2; }

# The version the volume currently has, straight from the installed manifest --
# the one source that cannot lie about what would actually be mounted.
installed_version() {
    local manifest="$PROFILE_DIR/node_modules/$1/package.json"
    [[ -f "$manifest" ]] || return 0
    sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -1
}

# Offline first: the image warmed the pnpm store at build time, so the normal
# case is a few hundred milliseconds and no registry traffic. An upgrade the
# store does not have yet falls through to the online path.
install_specs() {
    local log_file attempt args
    log_file="$(mktemp)"
    for attempt in offline online; do
        args=(plugin --profile "$PROFILE" add --save-exact)
        [[ "$attempt" == "offline" ]] && args+=(--offline)
        log "installing into profile $PROFILE ($attempt): $*"
        if timeout "${DSH_PLUGIN_TIMEOUT:-600}" dsh "${args[@]}" "$@" \
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
    warn "no plugin specs: set DSH_PLUGIN_SPECS, or run dsh-entrypoint.sh which loads specs.env"
    exit 0
fi

if ! mkdir -p "$DSH_HOME_DIR/profiles"; then
    warn "cannot create $DSH_HOME_DIR/profiles -- skipping the plugin install"
    exit 0
fi

# Resolve every spec against the volume: install the ones that are missing or at
# another version, in one "dsh plugin add" call (pnpm resolves them together),
# and leave an already-correct profile completely untouched -- no network, no
# writes, so ordinary restarts are fast and work offline.
todo=()
for spec in $PLUGIN_SPECS; do
    name="${spec%@*}"
    want="${spec##*@}"
    have="$(installed_version "$name")"
    if [[ "$have" == "$want" && "$REFRESH" != "1" ]]; then
        log "$name@$want already installed"
    elif [[ -n "$have" ]]; then
        log "$name: $have -> $want"
        todo+=("$spec")
    else
        log "$name: not installed"
        todo+=("$spec")
    fi
done

if (( ${#todo[@]} > 0 )); then
    if ! install_specs "${todo[@]}"; then
        warn "the container still starts, with whatever the volume already has"
    fi
else
    log "all pinned plugins match this image"
fi

apply_patch_layer
