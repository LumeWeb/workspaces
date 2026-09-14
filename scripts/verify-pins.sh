#!/bin/bash
# Verify the pinned upstream checksums are still correct against the live
# upstream sources. Fails loudly if any pin drifted.
#
# WordPress is intentionally not re-downloaded here: the Docker build already
# verifies the full archive sha256 (a mismatch fails the build), so re-fetching
# 37 MB per run would only contradict that same source.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_ENV="$SCRIPT_DIR/../images/php-caddy/versions.env"
WP_ENV="$SCRIPT_DIR/../images/wordpress/versions.env"

# shellcheck disable=SC1090
. "$BASE_ENV"
# shellcheck disable=SC1090
. "$WP_ENV"

echo "== [deps] checking Caddy checksums ($CADDY_VERSION) =="
curl -fsSL -o /tmp/caddy-checksums.txt \
    "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_checksums.txt"
for arch in amd64 arm64; do
    want=$(grep "caddy_${CADDY_VERSION}_linux_${arch}.deb" /tmp/caddy-checksums.txt | awk '{print $1}')
    var="CADDY_SHA512_$(echo "$arch" | tr '[:lower:]' '[:upper:]')"
    got="${!var}"
    if [ "$want" != "$got" ]; then
        echo "FAIL: Caddy $arch checksum drifted" >&2
        echo "  expected: $got" >&2
        echo "  upstream: $want" >&2
        exit 1
    fi
    echo "  ok  Caddy $arch sha512 matches upstream"
done

echo "== [deps] checking PHP base digest ($PHP_BASE) =="
upstream_digest="$(curl -fsSL \
    "https://hub.docker.com/v2/repositories/library/php/tags/${PHP_VERSION}-fpm-bookworm" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["digest"])')"
if [ "$upstream_digest" != "${PHP_BASE_DIGEST#sha256:}" ] && \
   [ "$upstream_digest" != "$PHP_BASE_DIGEST" ]; then
    echo "FAIL: PHP digest drifted" >&2
    echo "  expected: $PHP_BASE_DIGEST" >&2
    echo "  upstream: $upstream_digest" >&2
    exit 1
fi
echo "  ok  PHP ${PHP_VERSION} digest matches upstream"

echo "== [deps] WordPress ${WORDPRESS_VERSION} =="
echo "  WordPress archive sha256 is verified at Docker build time (skip here)."
echo "  pinned: $WORDPRESS_SHA256"

echo "== [deps] ALL PINS VERIFIED =="
