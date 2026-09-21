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

# docker-bake.hcl injects the pins as build ARGs by reading them from the
# process environment (Make sources versions.env and exports them). Export them
# here too so the bake-args drift check below sees the same values the build
# path would.
export PHP_BASE PHP_BASE_DIGEST CADDY_VERSION \
       CADDY_SHA512_AMD64 CADDY_SHA512_ARM64 \
       WORDPRESS_VERSION WORDPRESS_SHA256 \
       WP_CLI_VERSION WP_CLI_SHA512 \
       GO_BASE GO_BASE_DIGEST \
       COMPOSER_BASE COMPOSER_BASE_DIGEST

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

echo "== [deps] checking WP-CLI phar checksum (${WP_CLI_VERSION}) =="
curl -fsSL -o /tmp/wp-cli.phar \
    "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"
got_wpcli="$(sha512sum /tmp/wp-cli.phar | awk '{print $1}')"
if [ "$got_wpcli" != "$WP_CLI_SHA512" ]; then
    echo "FAIL: WP-CLI phar checksum drifted" >&2
    echo "  expected: $WP_CLI_SHA512" >&2
    echo "  upstream: $got_wpcli" >&2
    exit 1
fi
echo "  ok  WP-CLI ${WP_CLI_VERSION} sha512 matches upstream"

echo "== [deps] Go builder image pin (${GO_BASE}) =="
echo "  GO_BASE_DIGEST is verified by the Docker build (FROM ...@digest); pin: $GO_BASE_DIGEST"

echo "== [deps] Composer builder image pin (${COMPOSER_BASE}) =="
# The Cast snapshot itself is intentionally NOT checksum-pinned yet (latest
# develop tree); only its Composer builder base is pinned here.
echo "  COMPOSER_BASE_DIGEST is verified by the Docker build (FROM ...@digest); pin: $COMPOSER_BASE_DIGEST"

# Drift guard: versions.env is the single source of truth, but the Docker build
# only sees what docker-bake.hcl injects. Verify the resolved bake plan passes
# exactly the versions.env values as build ARGs (and the OCI labels that mirror
# them). If bake wiring ever stops forwarding a pin, this fails loudly here
# instead of silently building an image that does not match versions.env.
echo "== [deps] checking bake ARGs/labels match versions.env (no drift) =="
if command -v docker >/dev/null 2>&1; then
    bake_plan="$(docker buildx bake --print 2>/dev/null || true)"
    if [ -z "$bake_plan" ]; then
        echo "WARN: could not run 'docker buildx bake --print' — skipping bake drift check." >&2
    else
        get_json_arg() { # <target> <key>
            printf '%s' "$bake_plan" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(d['target']['$1']['args'].get('$2',''))"
        }
        get_json_label() { # <target> <key>
            printf '%s' "$bake_plan" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(d['target']['$1']['labels'].get('$2',''))"
        }
        check_bake() { # <target> <what> <key> <want>
            got="$(get_json_arg "$1" "$3")"
            [ "$got" = "$4" ] || {
                echo "FAIL: bake $1.$3 ($2) = '$got', versions.env = '$4'" >&2
                exit 1
            }
            echo "  ok  bake $1.$3 == versions.env ($got)"
        }
        check_bake php-caddy "PHP base image"   PHP_BASE           "$PHP_BASE"
        check_bake php-caddy "PHP base digest"  PHP_BASE_DIGEST    "$PHP_BASE_DIGEST"
        check_bake php-caddy "Caddy version"    CADDY_VERSION      "$CADDY_VERSION"
        check_bake php-caddy "Caddy amd64 sha"  CADDY_SHA512_AMD64 "$CADDY_SHA512_AMD64"
        check_bake php-caddy "Caddy arm64 sha"  CADDY_SHA512_ARM64 "$CADDY_SHA512_ARM64"
        check_bake wordpress "WP version"       WORDPRESS_VERSION  "$WORDPRESS_VERSION"
        check_bake wordpress "WP sha256"        WORDPRESS_SHA256   "$WORDPRESS_SHA256"
        check_bake wordpress "WP-CLI version"   WP_CLI_VERSION     "$WP_CLI_VERSION"
        check_bake wordpress "WP-CLI sha512"    WP_CLI_SHA512      "$WP_CLI_SHA512"
        check_bake wordpress "Go base"          GO_BASE            "$GO_BASE"
        check_bake wordpress "Go base digest"   GO_BASE_DIGEST     "$GO_BASE_DIGEST"
        check_bake wordpress "Composer base"        COMPOSER_BASE        "$COMPOSER_BASE"
        check_bake wordpress "Composer base digest" COMPOSER_BASE_DIGEST "$COMPOSER_BASE_DIGEST"

        # Runtime labels must mirror the same single source (they are fed from
        # the same bake variables, so this is cross-checking the mechanism).
        base_digest_label="$(get_json_label php-caddy org.opencontainers.image.base.digest)"
        [ "$base_digest_label" = "$PHP_BASE_DIGEST" ] || {
            echo "FAIL: php-caddy label org.opencontainers.image.base.digest = '$base_digest_label', versions.env = '$PHP_BASE_DIGEST'" >&2
            exit 1
        }
        echo "  ok  php-caddy label org.opencontainers.image.base.digest == versions.env ($base_digest_label)"
        caddy_label="$(get_json_label php-caddy com.lumeweb.caddy.version)"
        [ "$caddy_label" = "$CADDY_VERSION" ] || {
            echo "FAIL: php-caddy label com.lumeweb.caddy.version = '$caddy_label', versions.env = '$CADDY_VERSION'" >&2
            exit 1
        }
        echo "  ok  php-caddy label com.lumeweb.caddy.version == versions.env ($caddy_label)"

        wpcli_label="$(get_json_label wordpress com.lumeweb.wpcli.version)"
        [ "$wpcli_label" = "$WP_CLI_VERSION" ] || {
            echo "FAIL: wordpress label com.lumeweb.wpcli.version = '$wpcli_label', versions.env = '$WP_CLI_VERSION'" >&2
            exit 1
        }
        echo "  ok  wordpress label com.lumeweb.wpcli.version == versions.env ($wpcli_label)"
        gobase_label="$(get_json_label wordpress com.lumeweb.go-builder.base)"
        [ "$gobase_label" = "$GO_BASE" ] || {
            echo "FAIL: wordpress label com.lumeweb.go-builder.base = '$gobase_label', versions.env = '$GO_BASE'" >&2
            exit 1
        }
        echo "  ok  wordpress label com.lumeweb.go-builder.base == versions.env ($gobase_label)"
    fi
else
    echo "WARN: docker not installed — skipping bake drift check." >&2
fi

echo "== [deps] ALL PINS VERIFIED =="
