#!/bin/sh
set -eu

# Pinner root entrypoint.
#
# Starts privileged (container runs as root by default) so child images can
# initialize and chown mounted volumes before any application process exists.
# Runs a child-provided init hook, then permanently drops to the unprivileged
# application user and execs the supervisor that runs Caddy + PHP-FPM.

# Privileged startup hook, set by images that must prepare persistent mounts
# (see images/wordpress). Runs as root; afterwards we never regain it.
if [ -n "${PINNER_INIT:-}" ] && [ -x "$PINNER_INIT" ]; then
    "$PINNER_INIT" "$@"
fi

# Validate/prepare the workspace HTTP Basic Auth and export the derived hash
# into this (about-to-be-dropped) environment so Caddy can enforce it. Runs
# after the child init hook and before the privilege drop; it fails closed
# when the WORKSPACE_AUTH_* secrets are missing, so the container will not
# start unauthenticated. The exported variables survive setpriv (which
# preserves the environment) into the supervisor and, from there, Caddy.
. /usr/local/bin/pinner-auth-setup.sh

# Drop privileges for the entire rest of the process tree. setpriv keeps the
# same environment and execs the supervisor as www-data, so both Caddy and
# PHP-FPM (and every process they spawn) are non-root from here on.
exec setpriv --reuid=www-data --regid=www-data --init-groups \
    env HOME=/var/www \
    /usr/local/bin/pinner-supervise.sh "$@"
