#!/bin/bash
# Verify the php-caddy base image: boot it, prove PHP-backed /healthz, assert
# the workspace HTTP Basic Auth contract (portal-plugin-ipfs PR #1031), and
# assert the final Caddy/PHP-FPM processes are non-root.
#
# Auth contract under test (the bypass keys on the real TCP peer via Caddy's
# remote_ip matcher; loopback and private-network peers are in-deployment and
# exempt — see images/php-caddy/Caddyfile):
#   - public-range peer without credentials -> 401 (via the TEST-NET-1
#     ${compose}_publictest network, so the peer is genuinely 192.0.2.x)
#   - valid credentials -> 200 / app access
#   - bad credentials -> 401
#   - private-network peer (RFC1918/ULA) -> 200 with NO credentials
#     (in-deployment peer: the container's Docker network, and every
#     published-port hairpin NAT, falls under this case)
#   - loopback /healthz (127.0.0.1) -> 200 with NO credentials
#   - spoofed X-Forwarded-For / X-Real-IP never bypass auth on a public peer
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

# Local verification must never exercise a published/remote GHCR image: build
# + load locally first (make build) and pass the local tag. Reject anything that
# looks like a registry reference or is absent from the local daemon.
require_local_image "$IMAGE"

# Host port the compose maps to the container listener; must match the
# php-caddy.local.yaml port mapping below so a custom HOST_PORT works.
HOST_PORT="${HOST_PORT:-8081}"
COMPOSE="docker compose -f compose/php-caddy.local.yaml"
# Networks created by the compose stack: the default bridge (private-range
# peers) and the TEST-NET-1 bridge (public-range peers).
PUBLICNET="pinner-php-caddy-local_publictest"
PRIVATENET="pinner-php-caddy-local_default"

# Run curl with a given real TCP peer network. Uses the built image's own curl
# with entrypoint overridden, keeping local verification free of extra pulls.
peer_curl() {
    net="$1"; shift
    docker run --rm --network "$net" --entrypoint curl "$IMAGE" -s \
        -o /dev/null -w '%{http_code}' "$@"
}

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

echo "== [php-caddy] public-range (external) peer auth enforcement =="
# Requests from a peer on the TEST-NET-1 network carry a public-range TCP peer
# (192.0.2.x), which is the contract's "external" case: auth required.
code="$(peer_curl "$PUBLICNET" "http://web:8080/healthz")"
[ "$code" = "401" ] || die "public-peer no-auth expected 401, got $code"
pass "public-range peer without credentials -> 401"

code="$(peer_curl "$PUBLICNET" -u "$AUTH_USER:wrongpass" "http://web:8080/healthz")"
[ "$code" = "401" ] || die "bad credentials expected 401, got $code"
pass "public-range peer with bad credentials -> 401"

code="$(peer_curl "$PUBLICNET" -u "$AUTH_USER:$AUTH_PASS" "http://web:8080/healthz")"
[ "$code" = "200" ] || die "valid credentials expected 200, got $code"
pass "public-range peer with valid credentials -> 200"

echo "== [php-caddy] private-network peer bypass =="
# A peer on the compose default bridge has an RFC1918 TCP peer address: the
# in-deployment case (includes every published-port hairpin NAT). Exempt.
code="$(peer_curl "$PRIVATENET" "http://web:8080/healthz")"
[ "$code" = "200" ] || die "private-peer no-auth expected 200, got $code"
pass "private-network peer without credentials -> 200"

echo "== [php-caddy] spoofed forwarding headers must not bypass auth =="
# The bypass keys on Caddy's remote_ip (the real TCP peer of the request). A
# spoofed X-Forwarded-For/X-Real-IP claiming loopback must NOT exempt a
# public-range request, because its actual peer is 192.0.2.x.
code="$(peer_curl "$PUBLICNET" -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Real-IP: 127.0.0.1' "http://web:8080/healthz")"
[ "$code" = "401" ] || die "spoofed XFF/X-Real-IP must not bypass auth, got $code"
pass "spoofed X-Forwarded-For/X-Real-IP (claiming loopback) from public peer -> 401"

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
