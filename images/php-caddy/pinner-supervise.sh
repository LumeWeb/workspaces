#!/bin/sh
set -eu

# Runs PHP-FPM and Caddy together as the (already dropped) unprivileged user.
#
# We background PHP-FPM and keep a trap that forwards TERM/INT/QUIT to both
# children so a container shutdown stops FPM cleanly instead of orphaning it
# (QUIT is handled too: the official php base image sets STOPSIGNAL SIGQUIT, and
# being PID1 means an unhandled signal is silently ignored by the kernel, which
# would make `docker stop` hang until SIGKILL). Caddy stays a direct child of
# this supervisor, which exits with Caddy's status.
php-fpm -F &
php_pid=$!

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
caddy_pid=$!

# shellcheck disable=SC2317  # shutdown is reached only via trap, never inline
shutdown() {
    trap - TERM INT QUIT
    kill -TERM "$caddy_pid" 2>/dev/null || true
    wait "$caddy_pid" 2>/dev/null || true
    kill -TERM "$php_pid" 2>/dev/null || true
    wait "$php_pid" 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT QUIT

# Wait on Caddy; when it exits (or is terminated) stop PHP-FPM too.
caddy_status=0
wait "$caddy_pid" || caddy_status=$?
kill -TERM "$php_pid" 2>/dev/null || true
wait "$php_pid" 2>/dev/null || true
exit "$caddy_status"
