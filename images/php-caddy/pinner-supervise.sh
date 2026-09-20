#!/bin/sh
set -eu

# Runs the application processes together as the (already dropped) unprivileged
# user.
#
# Default children: PHP-FPM and Caddy. Child images may add ONE extra
# supervised long-running worker (e.g. the WordPress cron driver) by exporting
# PINNER_SUPERVISED_CMD (an `sh` command line, evaluated in the child wrapper).
# The worker has exactly the same lifecycle guarantees as the built-ins.
#
# This script is POSIX sh (dash/busybox ash) and therefore cannot use the
# Bash-only `wait -n` to learn which child exits first. Instead each process is
# owned by a tiny wrapper subshell that reaps it (so a crashed child never
# lingers as a zombie) and publishes its exit status through a named pipe. The
# supervisor blocks reading that pipe: the moment a child dies the read returns,
# every surviving child is terminated, all wrappers are awaited (reaping any
# leftover), and the supervisor exits with the dead child's status.
#
# TERM/INT/QUIT are trapped to shut all processes down gracefully (the official
# php base image sets STOPSIGNAL SIGQUIT, and as PID 1 an *unhandled* signal is
# silently ignored by the kernel, which would make `docker stop` hang until
# SIGKILL). We override to SIGTERM in the Dockerfile and forward it to all
# children here.

# Shared scratch dir + named pipe used for first-exit notification.
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/pinner-supervise.XXXXXX")
fifo="$tmpdir/exit.fifo"
mkfifo "$fifo"

cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# start_child <label> <pid-file> <command-line>
#
# Every child gets its own wrapper subshell: it starts the command (evaluated as
# a shell line so built-ins like options/arguments stay expressible), records
# the child's real PID (so the supervisor signals the exact process, never the
# whole group), waits for it (reaping it) and publishes a "<label>:<status>"
# line to $fifo. A failing child cannot trip the inherited `set -e` and abort
# its wrapper BEFORE it reports to the pipe (which would deadlock the
# supervisor's blocking read) because `wait`'s status is captured with `||`.
start_child() {
    label="$1" pidfile="$2" cmdline="$3"
    (
        eval "$cmdline &"
        pid=$!
        echo "$pid" > "$pidfile"
        st=0
        wait "$pid" || st=$?
        echo "$label:$st" > "$fifo"
    ) &
}

# Byzantine-general: every (possibly still pending) child pid file, newest first
# so a late-written file cannot be missed by a shutdown racing startup.
list_pidfiles() {
    if [ -n "${PINNER_SUPERVISED_CMD:-}" ]; then
        printf '%s\n' "$tmpdir/worker.pid"
    fi
    printf '%s\n' "$tmpdir/php.pid" "$tmpdir/caddy.pid"
}

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
    # The trap may fire during the brief startup handshake, before the wrappers
    # have written their PID files. Wait (bounded) for each expected pid file,
    # then terminate the exact child processes (never the process group). A pid
    # file that never appears simply results in no kill for that child.
    for pf in $(list_pidfiles); do
        i=0
        while [ ! -s "$pf" ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
        kill_child "$(cat "$pf" 2>/dev/null || true)"
    done
    wait || true
    exit 0
}
# Install the graceful-stop trap EARLY (before the startup waits below) so a
# signal that arrives during the pid-file handshake still shuts us down cleanly
# instead of hitting the kernel default (SIGTERM would kill us with 143 and
# leave the children orphaned).
trap shutdown TERM INT QUIT

# Launch the supervised children. The worker comes first so a signal that lands
# during the handshake is handled for it right after the built-ins.
if [ -n "${PINNER_SUPERVISED_CMD:-}" ]; then
    start_child worker "$tmpdir/worker.pid" "$PINNER_SUPERVISED_CMD"
fi
start_child php "$tmpdir/php.pid" 'php-fpm -F'
start_child caddy "$tmpdir/caddy.pid" 'caddy run --config /etc/caddy/Caddyfile --adapter caddyfile'

# The wrappers always write their PID files before their child can report an
# exit, so block until all expected pid files are present; only then do we have
# exact PIDs for a robust peer shutdown (no PID races from an empty file).
for pf in $(list_pidfiles); do
    while [ ! -s "$pf" ]; do sleep 1; done
done

# Open the pipe read-write for the whole lifetime. Ordering matters twice over:
#   * opening read-only (3<) would BLOCK until a writer appears and is subject
#     to EINTR (a SIGCHLD can interrupt the blocking open and abort the shell);
#   * opening read-write (3<>) never blocks and gives the pipe a permanent
#     reader, so a wrapper writing to it (even a late survivor after we signal
#     it) never blocks on open()/write() and we never deadlock.
exec 3<> "$fifo"

# Block until the first child exits, then terminate every survivor and reap all
# wrappers. (The dead child's own wrapper has already reaped it.)
read -r notice <&3
name=${notice%%:*}
status=${notice#*:}

for pf in $(list_pidfiles); do
    [ "$(basename "$pf" .pid)" = "$name" ] && continue   # already dead
    kill_child "$(cat "$pf" 2>/dev/null || true)"
done
wait || true

# A supervised process should not exit cleanly on its own while we are up; if
# it coincidentally did (status 0), still report failure so the orchestrator
# knows a co-process went down. A nonzero status is preserved verbatim.
if [ "$status" -eq 0 ]; then
    status=1
fi
exit "$status"
