#!/bin/sh
# Deterministic regression harness for images/php-caddy/pinner-supervise.sh.
#
# The supervisor keeps two co-processes (Caddy + PHP-FPM) — plus, when
# PINNER_SUPERVISED_CMD is exported, one extra accounted worker child (the
# WordPress cron driver) — alive, and must NOT exit while all are healthy. This
# harness proves the reverse requirement — that the supervisor tears down and
# exits whenever ANY child fails — plus that a normal docker-stop signal (TERM)
# still shuts down cleanly with status 0.
#
# It runs the *real* supervisor script against stub `php-fpm` / `caddy` /
# worker executables placed on PATH (the supervisor invokes the built-ins via
# PATH lookup and the worker via PINNER_SUPERVISED_CMD, so no image build is
# needed). Each stub records its PID so the harness can later assert the
# process was terminated AND reaped (an unreaped zombie still answers `kill -0`).
#
# Scenarios:
#   1. php-fpm exits nonzero  -> supervisor exits nonzero (status: 7)
#   2. caddy exits nonzero    -> supervisor exits nonzero (status: 9)
#   3. worker exits nonzero   -> supervisor exits nonzero (status: 11)
#   4. php-fpm crash, worker healthy -> worker reaped as survivor
#   5. TERM while all three healthy  -> supervisor exits 0, all cleaned up
#   +. TERM/INT/QUIT while both built-ins healthy -> exit 0, both cleaned up
#
# Usage: scripts/test-supervisor.sh [path-to-pinner-supervise.sh]

set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SUPERVISOR="${1:-$SCRIPT_DIR/../images/php-caddy/pinner-supervise.sh}"

[ -r "$SUPERVISOR" ] || { echo "cannot read supervisor: $SUPERVISOR" >&2; exit 1; }
# The supervisor must stay POSIX (no Bash `wait -n`); dash satisfies this.
if ! command -v dash >/dev/null 2>&1; then
    echo "SKIP: dash not available (needed to prove POSIX-only supervisor)" >&2
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pinner-supervise-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Stub php-fpm: on FAIL_PHP it exits immediately with that status (crash);
# otherwise it is a healthy long-running worker that exits 0 on TERM/INT/QUIT.
# PID is written to php_stub.pid for post-mortem liveness checks.
cat > "$WORK/bin/php-fpm" <<'EOF'
#!/bin/sh
# Record our PID first so the harness can assert even a *failed* child was
# reaped (a zombie would still answer `kill -0`).
echo "$$" > "$php_stub_pidfile"
if [ -n "${FAIL_PHP:-}" ]; then
    exit "$FAIL_PHP"
fi
trap 'exit 0' TERM INT QUIT
while :; do sleep 1; done
EOF

# Stub caddy: mirrors php-fpm (FAIL_CADDY -> immediate exit, else long-running).
cat > "$WORK/bin/caddy" <<'EOF'
#!/bin/sh
echo "$$" > "$caddy_stub_pidfile"
if [ -n "${FAIL_CADDY:-}" ]; then
    exit "$FAIL_CADDY"
fi
trap 'exit 0' TERM INT QUIT
while :; do sleep 1; done
EOF
chmod +x "$WORK/bin/php-fpm" "$WORK/bin/caddy"

# Stub optional supervised worker (enabled per scenario via USES_WORKER=1):
# mirrors php-fpm (FAIL_WORKER -> immediate exit, else long-running).
cat > "$WORK/bin/worker" <<'EOF'
#!/bin/sh
echo "$$" > "$worker_stub_pidfile"
if [ -n "${FAIL_WORKER:-}" ]; then
    exit "$FAIL_WORKER"
fi
trap 'exit 0' TERM INT QUIT
while :; do sleep 1; done
EOF
chmod +x "$WORK/bin/worker"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# assert_no_live(pidfile, label): the recorded child PID must no longer exist
# (terminated + reaped). A zombie still answers `kill -0` successfully, so this
# also guards against leftover unreaped children.
assert_reaped() {
    pidfile=$1; label=$2
    [ -s "$pidfile" ] || fail "$label: pidfile '$pidfile' was never written (child never ran)"
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
        fail "$label (pid $pid) still alive/zombie after supervisor exit"
    fi
    pass "$label (pid $pid) terminated and reaped"
}

run_supervisor() {
    # $1 = "healthy"|"fail-php"|"fail-caddy"|"fail-worker". The optional
    # supervised worker is enabled only when the harness exported USES_WORKER=1
    # before calling (worker env is always pinned so no leak across scenarios).
    mode=$1
    (
        cd "$WORK"
        unset FAIL_PHP FAIL_CADDY FAIL_WORKER
        case "$mode" in
            fail-php)    FAIL_PHP=7    ;;
            fail-caddy)  FAIL_CADDY=9  ;;
            fail-worker) FAIL_WORKER=11 ;;
        esac
        if [ "${USES_WORKER:-0}" = "1" ]; then
            export PINNER_SUPERVISED_CMD="$WORK/bin/worker" \
                   worker_stub_pidfile="$WORK/worker_stub.pid"
            rm -f "$WORK/worker_stub.pid"
        else
            export PINNER_SUPERVISED_CMD=
        fi
        # Import the stub env vars into the supervisor's spawned children.
        export FAIL_PHP FAIL_CADDY FAIL_WORKER php_stub_pidfile="$WORK/php_stub.pid" \
               caddy_stub_pidfile="$WORK/caddy_stub.pid" PATH="$WORK/bin:$PATH"
        rm -f "$WORK/php_stub.pid" "$WORK/caddy_stub.pid"
        # Invoke via `sh` so the harness runs even though the repo scripts are
        # not committed with the +x bit (the image Dockerfile chmod +x's it).
        exec sh "$SUPERVISOR"
    )
}

echo "== scenario 1: php-fpm exits nonzero -> supervisor exits nonzero =="
st=0
run_supervisor fail-php || st=$?   # || so set -e does not abort on the expected failure
[ "$st" -ne 0 ] || fail "supervisor exited 0 when php-fpm crashed (expected nonzero)"
[ "$st" -eq 7 ] || fail "supervisor exited $st, expected preserved child status 7"
pass "php-fpm crash -> supervisor exit $st (nonzero, child status preserved)"
assert_reaped "$WORK/php_stub.pid"   "php-fpm stub"
assert_reaped "$WORK/caddy_stub.pid" "caddy stub (survivor)"

echo "== scenario 2: caddy exits nonzero -> supervisor exits nonzero =="
st=0
run_supervisor fail-caddy || st=$?
[ "$st" -ne 0 ] || fail "supervisor exited 0 when caddy crashed (expected nonzero)"
[ "$st" -eq 9 ] || fail "supervisor exited $st, expected preserved child status 9"
pass "caddy crash -> supervisor exit $st (nonzero, child status preserved)"
assert_reaped "$WORK/caddy_stub.pid" "caddy stub"
assert_reaped "$WORK/php_stub.pid"   "php-fpm stub (survivor)"

# signal_shutdown(signal): start a healthy supervisor, let both children
# register, send $signal (the docker-stop signal), and require a clean exit 0
# with both children terminated + reaped. The supervisor must trap TERM/INT/QUIT
# (STOPSIGNAL is overridden to SIGTERM; the php base image uses SIGQUIT) and
# forward them to both children for a graceful `docker stop`.
#
# IMPORTANT launch detail: the supervisor is started via `exec` in its own
# helper process with a BACKGROUND sender delivering the signal. A POSIX shell
# that starts a job with `&` pre-ignores SIGINT/SIGQUIT in that job, so the
# supervisor's INT/QUIT traps could never fire if we backgrounded it directly.
# By `exec`-ing the supervisor as the helper's own process (which, because a
# subshell inherits the invoking shell's PID for `$$`, also gives the sender the
# exact supervisor PID), SIGINT/SIGQUIT keep their default dispositions and the
# traps run exactly as they do when the supervisor is PID 1 in the container.
signal_shutdown() {
    sig=$1
    # Worker-aware env + readiness probe: with USES_WORKER=1 the sender waits
    # for all three children to register before signalling.
    if [ "${USES_WORKER:-0}" = "1" ]; then
        worker_env="export PINNER_SUPERVISED_CMD='$WORK/bin/worker' worker_stub_pidfile='$WORK/worker_stub.pid'; rm -f '$WORK/worker_stub.pid';"
        waitall="[ ! -s '$WORK/php_stub.pid' ] || [ ! -s '$WORK/caddy_stub.pid' ] || [ ! -s '$WORK/worker_stub.pid' ]"
    else
        worker_env="export PINNER_SUPERVISED_CMD=;"
        waitall="[ ! -s '$WORK/php_stub.pid' ] || [ ! -s '$WORK/caddy_stub.pid' ]"
    fi
    helper="$WORK/signal_probe.sh"
    cat > "$helper" <<HELPER
#!/bin/sh
set -u
SUPERVISOR='$SUPERVISOR'
WORK='$WORK'
export php_stub_pidfile='$WORK/php_stub.pid' caddy_stub_pidfile='$WORK/caddy_stub.pid'
$worker_env
export PATH="$WORK/bin:$PATH"
rm -f '$WORK/php_stub.pid' '$WORK/caddy_stub.pid'
# Background sender: once every stub child registers, deliver \$sig to \$\$
# (== the helper PID, which is the supervisor PID after the exec below).
(
    i=0
    while $waitall; do
        i=\$((i + 1)); [ "\$i" -le 200 ] || exit 1; sleep 0.05
    done
    sleep 0.5
    kill -$sig "\$\$"
) &
# Foreground exec: supervisor becomes this helper's own process (same PID), so
# INT/QUIT are not pre-ignored and the traps run; exit status propagates.
exec sh "\$SUPERVISOR"
HELPER
    st=0
    sh "$helper" || st=$?
    [ "$st" -eq 0 ] || fail "$sig shutdown did not exit 0 (exit $st)"
}

# Each of TERM (docker stop default), INT and QUIT (the php base image's
# STOPSIGNAL) must shut the healthy supervisor down cleanly with exit 0.
for _sig in TERM INT QUIT; do
    echo "== scenario [signal]: $_sig while both healthy -> clean shutdown, exit 0 =="
    signal_shutdown "$_sig" || fail "signal shutdown for $_sig failed"
    pass "$_sig signal -> supervisor exit 0 (clean docker stop)"
    assert_reaped "$WORK/php_stub.pid"   "php-fpm stub"
    assert_reaped "$WORK/caddy_stub.pid" "caddy stub"
done

# ---- optional supervised worker (PINNER_SUPERVISED_CMD) ---------------------

# The worker (used by the WordPress image for its WP-CLI cron driver) must obey
# exactly the same lifecycle guarantees as the built-in children.

echo "== scenario 3: worker exits nonzero -> supervisor exits with its status =="
USES_WORKER=1
st=0
run_supervisor fail-worker || st=$?
[ "$st" -ne 0 ] || fail "supervisor exited 0 when worker crashed (expected nonzero)"
[ "$st" -eq 11 ] || fail "supervisor exited $st, expected preserved worker status 11"
pass "worker crash -> supervisor exit $st (nonzero, worker status preserved)"
assert_reaped "$WORK/worker_stub.pid" "worker stub"
assert_reaped "$WORK/php_stub.pid"   "php-fpm stub (survivor)"
assert_reaped "$WORK/caddy_stub.pid" "caddy stub (survivor)"

echo "== scenario 4: php crash with worker healthy -> worker reaped as survivor =="
st=0
run_supervisor fail-php || st=$?
[ "$st" -ne 0 ] || fail "supervisor exited 0 when php-fpm crashed (expected nonzero)"
[ "$st" -eq 7 ] || fail "supervisor exited $st, expected preserved child status 7"
assert_reaped "$WORK/php_stub.pid"   "php-fpm stub"
assert_reaped "$WORK/worker_stub.pid" "worker stub (survivor)"
assert_reaped "$WORK/caddy_stub.pid" "caddy stub (survivor)"
pass "php crash with worker healthy -> all children terminated and reaped"

echo "== scenario 5: TERM while all three healthy -> clean shutdown, exit 0 =="
signal_shutdown TERM || fail "TERM shutdown with worker failed"
pass "TERM with worker -> supervisor exit 0 (clean docker stop)"
assert_reaped "$WORK/php_stub.pid"    "php-fpm stub"
assert_reaped "$WORK/caddy_stub.pid"  "caddy stub"
assert_reaped "$WORK/worker_stub.pid" "worker stub"

echo "== supervisor harness OK =="
