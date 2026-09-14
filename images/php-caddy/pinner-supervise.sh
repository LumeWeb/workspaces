#!/bin/sh
set -eu

# Runs PHP-FPM and Caddy together as the (already dropped) unprivileged user.
#
# This script is POSIX sh (dash/busybox ash) and therefore cannot use the
# Bash-only `wait -n` to learn which child exits first. Instead each process is
# owned by a tiny wrapper subshell that reaps it (so a crashed child never
# lingers as a zombie) and publishes its exit status through a named pipe. The
# supervisor blocks reading that pipe: the moment a child dies the read returns,
# the surviving partner is terminated, both wrappers are awaited (reaping any
# leftover), and the supervisor exits with the dead child's status.
#
# TERM/INT/QUIT are trapped to shut both processes down gracefully (the official
# php base image sets STOPSIGNAL SIGQUIT, and as PID 1 an *unhandled* signal is
# silently ignored by the kernel, which would make `docker stop` hang until
# SIGKILL). We override to SIGTERM in the Dockerfile and forward it to both
# children here.

# Shared scratch dir + named pipe used for first-exit notification.
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/pinner-supervise.XXXXXX")
fifo="$tmpdir/exit.fifo"
mkfifo "$fifo"
php_pid=0
caddy_pid=0

cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# Each wrapper starts its child, records the child's real PID, waits for it
# (reaping it) and publishes a "<name>:<status>" line to $fifo. The actual app
# process is a child of the wrapper, so the wrapper's `wait` reaps it and no
# zombie is ever left behind. The supervisor reads the PID back from the file
# so it can signal the exact process.
(
    php-fpm -F &
    php_pid=$!
    echo "$php_pid" > "$tmpdir/php.pid"
    # Capture the exit status with `||` so a failing child does not trip the
    # inherited `set -e` and abort this wrapper BEFORE it reports to the pipe
    # (which would deadlock the supervisor's blocking read).
    st=0
    wait "$php_pid" || st=$?
    echo "php:$st" > "$fifo"
) &

(
    caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
    caddy_pid=$!
    echo "$caddy_pid" > "$tmpdir/caddy.pid"
    st=0
    wait "$caddy_pid" || st=$?
    echo "caddy:$st" > "$fifo"
) &

# shellcheck disable=SC2317  # kill_child is reached only via shutdown/survivor
kill_child() {
    # $1 = pid; guard against 0 (invalid/safe-to-ignore) so we never signal the
    # whole process group with `kill -TERM 0`.
    pid="$1"
    [ "${pid:-0}" -gt 0 ] 2>/dev/null && kill -TERM "$pid" 2>/dev/null || true
}

# shellcheck disable=SC2317  # shutdown is reached only via trap, never inline
shutdown() {
    trap - TERM INT QUIT
    # If a signal arrives during the startup handshake, this shell has not yet
    # reached `exec 3<> "$fifo"` below. A wrapper that has just watched its
    # child die will try to `echo > "$fifo"`; writing a FIFO with no reader
    # BLOCKS, so `wait` below would deadlock with no one draining the pipe.
    # Open the FIFO read-write here (a no-op if fd 3 is already open) so a
    # wrapper's late status write can never block. Reopening an open fd with
    # `exec 3<>` simply clobbers fd 3, so this is also safe in the normal
    # post-startup signal case.
    exec 3<> "$fifo" 2>/dev/null || true
    # The trap may fire during the brief startup handshake, before this shell
    # has read the child PIDs (they would still be 0 / not yet cat'ed). In that
    # case fall back to the PID files the wrappers write, so we always terminate
    # the exact child processes (never the process group). kill_child() ignores
    # a 0/empty pid, so a file not yet written simply results in no kill.
    if ! [ "${php_pid:-0}" -gt 0 ] 2>/dev/null; then
        i=0; while [ ! -s "$tmpdir/php.pid" ] && [ "$i" -lt 50 ]; do i=$((i+1)); sleep 0.1; done
        php_pid=$(cat "$tmpdir/php.pid" 2>/dev/null || true)
    fi
    if ! [ "${caddy_pid:-0}" -gt 0 ] 2>/dev/null; then
        i=0; while [ ! -s "$tmpdir/caddy.pid" ] && [ "$i" -lt 50 ]; do i=$((i+1)); sleep 0.1; done
        caddy_pid=$(cat "$tmpdir/caddy.pid" 2>/dev/null || true)
    fi
    kill_child "$php_pid"
    kill_child "$caddy_pid"
    wait || true
    exit 0
}
# Install the graceful-stop trap EARLY (before the startup waits below) so a
# signal that arrives during the pid-file handshake still shuts us down cleanly
# instead of hitting the kernel default (SIGTERM would kill us with 143 and
# leave the children orphaned). kill_child() ignores a pid of 0, which is what
# shutdown() sees before the pid files have been read.
trap shutdown TERM INT QUIT

# The wrappers always write their PID files before their child can report an
# exit, so block until both are present; only then do we have exact PIDs for a
# robust peer shutdown (no PID races from an empty file).
for pf in "$tmpdir/php.pid" "$tmpdir/caddy.pid"; do
    while [ ! -s "$pf" ]; do sleep 1; done
done
php_pid=$(cat "$tmpdir/php.pid")
caddy_pid=$(cat "$tmpdir/caddy.pid")

# Open the pipe read-write for the whole lifetime. Ordering matters twice over:
#   * opening read-only (3<) would BLOCK until a writer appears and is subject
#     to EINTR (a SIGCHLD can interrupt the blocking open and abort the shell);
#   * opening read-write (3<>) never blocks and gives the pipe a permanent
#     reader, so a wrapper writing to it (even a late survivor after we signal
#     it) never blocks on open()/write() and we never deadlock.
exec 3<> "$fifo"

# Block until the first child exits, then terminate the survivor and reap both.
read -r notice <&3
case "$notice" in
    php:*)   survivor=$caddy_pid ;;
    caddy:*) survivor=$php_pid ;;
    *)       survivor=$php_pid ;;  # defensive default: prefer php-fpm as peer
esac

kill_child "$survivor"
wait || true

status=${notice#*:}
# A supervised process should not exit cleanly on its own while we are up; if
# it coincidentally did (status 0), still report failure so the orchestrator
# knows a co-process went down. A nonzero status is preserved verbatim.
if [ "$status" -eq 0 ]; then
    status=1
fi
exit "$status"
