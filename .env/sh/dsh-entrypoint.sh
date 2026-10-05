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
# Lives in .env/sh/ and is COPYed into the image at /usr/local/bin/ by
# .env/Dockerfile. Keep it LF-only: .env/.gitattributes enforces that, and bash
# rejects a shebang or command ending in a stray carriage return.
set -euo pipefail

here="$(dirname "$(readlink -f "$0")")"
# The versions this image resolved from @latest at build time live next to the
# patch layer. Pass them down explicitly: sourcing the file would only set a
# shell variable here, and the provisioner runs as a child process. An explicit
# DSH_PLUGIN_SPECS in the environment still wins.
specs_env="${DSH_PLUGIN_HOME:-/opt/dsh-plugin}/specs.env"
if [[ -z "${DSH_PLUGIN_SPECS:-}" && -r "${specs_env}" ]]; then
    raw="$(sed -n 's/^DSH_PLUGIN_SPECS=//p' "${specs_env}" | head -1)"
    # The file holds a shell assignment, so let the shell parse its value
    # instead of stripping quotes by hand (it is written by this build).
    eval "DSH_PLUGIN_SPECS=${raw}"
    export DSH_PLUGIN_SPECS
fi
if [[ -x "$here/dsh-profile-provision.sh" ]]; then
    "$here/dsh-profile-provision.sh" "${DSH_SEED_PROFILES:-web}" || true
else
    printf 'dsh-entrypoint: WARNING: %s is missing; starting without provisioning plugins\n' \
        "$here/dsh-profile-provision.sh" >&2
fi

exec "$@"
