#!/bin/sh
# Shared helpers for the verification scripts.

set -eu

# Fail loudly with context.
die() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

# Poll an HTTP URL until it returns HTTP 200 (or a whole-prefix match),
# supplying HTTP Basic Auth credentials with each request (the workspace image
# enforces Basic Auth on non-loopback requests).
wait_http_auth() {
    url="$1"
    shift
    want="$1"
    shift
    user="$1"
    shift
    pass="$1"
    shift
    tries="${1:-60}"
    interval="${2:-3}"
    i=0
    while [ "$i" -lt "$tries" ]; do
        code="$(curl -s -u "$user:$pass" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
        if [ "${code:-}" = "$want" ]; then
            return 0
        fi
        i=$((i + 1))
        sleep "$interval"
    done
    die "never reached $want from $url (last code ${code:-none})"
}

# Poll an HTTP URL until it returns HTTP 200 (or a whole-prefix match).
wait_http() {
    url="$1"
    shift
    want="$1"
    shift
    tries="${1:-60}"
    interval="${2:-3}"
    i=0
    while [ "$i" -lt "$tries" ]; do
        code="$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
        if [ "${code:-}" = "$want" ]; then
            return 0
        fi
        i=$((i + 1))
        sleep "$interval"
    done
    die "never reached $want from $url (last code ${code:-none})"
}

# Print the numeric uid of www-data inside a running container.
app_uid_of() {
    container="$1"
    docker exec "$container" id -u www-data
}

# Assert that PHP-FPM and Caddy run as the given uid (i.e. non-root) in a
# running container, by reading /proc of every live process.
assert_nonroot() {
    container="$1"
    want_uid="$2"
    out="$(docker exec "$container" sh -c '
        for p in /proc/[0-9]*; do
            st="$p/status"; [ -r "$st" ] || continue
            name=$(sed -n "s/^Name:[[:space:]]*//p" "$st" 2>/dev/null || true)
            uid=$(sed -n "s/^Uid:[[:space:]]*//p" "$st" 2>/dev/null | awk "{print \$1}" || true)
            case "$name" in
                caddy|*php-fpm*) echo "$name:$uid" ;;
            esac
        done
    ')"
    echo "$out" | grep . >/dev/null || die "no caddy/php-fpm processes found"
    bad="$(echo "$out" | awk -F: -v want="$want_uid" '$2 != want {print}')"
    if [ -n "$bad" ]; then
        die "non-root violation (expected uid $want_uid): $bad"
    fi
    pass "caddy and php-fpm run as uid $want_uid (non-root)"
    echo "  $out"
}

# Assert a pid-1 process (the supervisor) runs as the given uid.
assert_pid1_nonroot() {
    container="$1"
    want_uid="$2"
    uid="$(docker exec "$container" sh -c 'stat -c %u /proc/1')"
    if [ "$uid" != "$want_uid" ]; then
        die "supervisor /proc/1 runs as uid $uid, expected non-root $want_uid"
    fi
    pass "supervisor (pid 1) runs as uid $uid (non-root)"
}
