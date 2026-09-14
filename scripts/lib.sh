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

# Refuse to verify an image reference that points at a published / remote
# registry. Local verification must ONLY exercise images that were just built
# and loaded into the local docker daemon (by `make build`, e.g.
# pinner-php-caddy:local). Pointing it at a registry reference (ghcr.io, any
# remote host, or a host:port) would require authentication or a clean pull —
# and silently reusing a stale locally-tagged GHCR image would mask what is
# actually being tested. Fail loudly instead.
require_local_image() {
    image="$1"
    case "$image" in
        */*)
            # A slash means an explicit first path component; if that component
            # carries a registry host (a dot, a port, or an explicit localhost /
            # IP / bracketed IPv6 literal) the reference is registry-qualified.
            host="${image%%/*}"
            case "$host" in
                *.*|*:*|localhost|'['*)
                    die "refusing to verify remote/published image '$image': local verification requires a locally built + loaded image (e.g. pinner-php-caddy:local). Build + load it first with 'make build'; never pass a GHCR/registry reference."
                    ;;
            esac
            ;;
    esac
    docker image inspect "$image" >/dev/null 2>&1 \
        || die "image '$image' is not present in the local docker daemon. Build + load it first with 'make build' (a bare/remote name would require a registry pull)."
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
