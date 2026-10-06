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
# DSH_PLUGIN_SPECS comes straight from the image's ENV (the one place the plugin
# list lives -- see .env/Dockerfile), overridable per container through .env.
# Nothing is read from a file: the list is installed again on every start, so
# there is no resolved-version file to load.
if [[ -x "$here/dsh-profile-provision.sh" ]]; then
    "$here/dsh-profile-provision.sh" "${DSH_SEED_PROFILES:-web}" || true
else
    printf 'dsh-entrypoint: WARNING: %s is missing; starting without provisioning plugins\n' \
        "$here/dsh-profile-provision.sh" >&2
fi

exec "$@"
