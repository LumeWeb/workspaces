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

# PHP log relay: stream PHP-FPM's error log — the single sink of all PHP
# application logs (error_log(), PHP warnings/errors captured by FPM's
# catch_workers_output) — into the container's stderr, so docker/Coolify
# `docker logs` carry them tagged "[php]". FPM writes to that file because the
# non-root master cannot reopen the container's root-owned log pipe (see
# php-fpm.conf); this relay is what makes the same bytes visible to the
# orchestrator. It is a sibling of the exec'd supervisor (which never waits on
# it), deliberately unsupervised: this is a best-effort mirror — if it dies the
# site keeps serving; logs keep accumulating in the file, just not streamed.
# The container runtime tears it down with the container. Started as www-data
# (it only reads that www-data-owned file), with its own TERM trap reset to the
# kernel default so it never inherits/executes a parent's signal handler.
setpriv --reuid=www-data --regid=www-data --init-groups sh -c '
    trap - TERM INT QUIT
    tail -F -n 0 /var/www/log/php-fpm.log 2>/dev/null | sed -u "s/^/[php] /"
' >&2 &

# Drop privileges for the entire rest of the process tree. setpriv keeps the
# same environment and execs the supervisor as www-data, so both Caddy and
# PHP-FPM (and every process they spawn) are non-root from here on.
exec setpriv --reuid=www-data --regid=www-data --init-groups \
    env HOME=/var/www \
    /usr/local/bin/pinner-supervise.sh "$@"
