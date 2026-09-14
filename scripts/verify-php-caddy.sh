#!/bin/bash
# Verify the php-caddy base image: boot it, prove PHP-backed /healthz, assert
# the workspace HTTP Basic Auth contract (portal-plugin-ipfs PR #1031), and
# assert the final Caddy/PHP-FPM processes are non-root.
#
# Auth contract under test:
#   - non-loopback (external-equivalent) requests without credentials -> 401
#   - valid credentials -> 200 / app access
#   - bad credentials -> 401
#   - loopback /healthz (127.0.0.1) -> 200 with NO credentials
#   - spoofed X-Forwarded-For / X-Real-IP never bypass auth on non-loopback
#   - IPv6 loopback (::1) bypass -> 200 when the environment supports it
#   - auth always required (no silent auth-disabled mode): the contract’s
#     environment builder fails closed, so there is deliberately no
#     "auth disabled" branch.
#
# Usage: verify-php-caddy.sh --image <image>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

IMAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="${2:?}"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -n "$IMAGE" ] || { echo "missing --image" >&2; exit 2; }

# Host port the compose maps to the container listener; must match the
# php-caddy.local.yaml port mapping below so a custom HOST_PORT works.
HOST_PORT="${HOST_PORT:-8081}"
COMPOSE="docker compose -f compose/php-caddy.local.yaml"

# Credentials the compose stack injects as the WORKSPACE_AUTH_* secrets
# (must match compose/php-caddy.local.yaml).
AUTH_USER="localuser"
AUTH_PASS="localpass"

trap 'docker compose -f compose/php-caddy.local.yaml down -v >/dev/null 2>&1 || true' EXIT

echo "== [php-caddy] booting base image: $IMAGE =="
PHP_CADDY_IMAGE="$IMAGE" $COMPOSE up -d
container="$($COMPOSE ps -q web)"

echo "== [php-caddy] waiting for authenticated PHP-backed /healthz =="
wait_http_auth "http://localhost:${HOST_PORT}/healthz" 200 "$AUTH_USER" "$AUTH_PASS" 40 3
body="$(curl -s -u "$AUTH_USER:$AUTH_PASS" "http://localhost:${HOST_PORT}/healthz")"
[ "$body" = "ok" ] || die "unexpected healthz body: '$body'"
pass "GET /healthz returns 200 via PHP with valid credentials (body='$body')"

echo "== [php-caddy] external (non-loopback) auth enforcement =="
code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${HOST_PORT}/healthz")"
[ "$code" = "401" ] || die "external no-auth expected 401, got $code"
pass "external-equivalent request without credentials -> 401"

code="$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH_USER:wrongpass" "http://localhost:${HOST_PORT}/healthz")"
[ "$code" = "401" ] || die "bad credentials expected 401, got $code"
pass "external request with bad credentials -> 401"

code="$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH_USER:$AUTH_PASS" "http://localhost:${HOST_PORT}/healthz")"
[ "$code" = "200" ] || die "valid credentials expected 200, got $code"
pass "external request with valid credentials -> 200"

echo "== [php-caddy] spoofed forwarding headers must not bypass auth =="
# The bypass keys on Caddy's remote_ip (the real TCP peer of the request). A
# spoofed X-Forwarded-For/X-Real-IP claiming loopback must NOT exempt an
# external request, because its actual peer is the docker bridge / non-loopback.
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Real-IP: 127.0.0.1' "http://localhost:${HOST_PORT}/healthz")"
[ "$code" = "401" ] || die "spoofed XFF/X-Real-IP must not bypass auth, got $code"
pass "spoofed X-Forwarded-For/X-Real-IP (claiming loopback) on non-loopback -> 401"

echo "== [php-caddy] loopback /healthz bypass =="
# docker exec curl against 127.0.0.1 inside the container: real peer is the
# loopback, so Caddy exempts it and no credentials are needed.
code="$(docker exec "$container" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/healthz")"
[ "$code" = "200" ] || die "loopback /healthz (127.0.0.1) expected 200, got $code"
pass "loopback /healthz (127.0.0.1) returns 200 with NO credentials"

# Loopback is genuinely exempt regardless of spoofed headers (the matcher
# never inspects them); this asserts peer-IP-based bypass, not header trust.
code="$(docker exec "$container" curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 8.8.8.8' -H 'X-Real-IP: 8.8.8.8' "http://127.0.0.1:8080/healthz")"
[ "$code" = "200" ] || die "loopback + foreign XFF expected 200, got $code"
pass "loopback /healthz + foreign X-Forwarded-For/X-Real-IP still 200 (peer-based bypass)"

echo "== [php-caddy] IPv6 loopback (::1) bypass (if supported) =="
if docker exec "$container" curl -s -o /dev/null -w '%{http_code}' 'http://[::1]:8080/healthz' >/dev/null 2>&1; then
    code="$(docker exec "$container" curl -s -o /dev/null -w '%{http_code}' 'http://[::1]:8080/healthz')"
    if [ "$code" = "200" ]; then
        pass "IPv6 loopback /healthz ([::1]) returns 200 with NO credentials"
    else
        die "IPv6 loopback expected 200, got $code"
    fi
else
    echo "SKIP: IPv6 loopback not reachable in this environment"
fi

want="$(app_uid_of "$container")"
assert_pid1_nonroot "$container" "$want"
assert_nonroot "$container" "$want"

echo "== [php-caddy] OK =="
