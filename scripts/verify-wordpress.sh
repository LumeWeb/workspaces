#!/bin/bash
# End-to-end local verification of the Pinner WordPress image with MariaDB.
#
# Proves: PHP-backed health, WordPress install, fresh-volume default theme,
# persistence of user content across container recreation, ephemeral core,
# non-overwrite of user content, deleted-plugin-not-resurrected, runtime-user
# writability, and non-root final processes.
#
# Usage: WORDPRESS_IMAGE=<image> verify-wordpress.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

COMPOSE="docker compose -f compose/wordpress.local.yaml"
SERVICE="wordpress"
HOST_PORT="${HOST_PORT:-8080}"
SITE_URL="http://localhost:${HOST_PORT}"

# Workspace HTTP Basic Auth credentials the compose stack injects
# (must match compose/wordpress.local.yaml). Host->container requests are
# non-loopback and therefore require auth; in-container loopback bypasses.
AUTH_USER="localuser"
AUTH_PASS="localpass"

# wp-cli pinned for deterministic verification (not shipped in the image).
WP_CLI_VERSION="2.12.0"
WP_CLI_SHA512="be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832"
WP_CLI_URL="https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"

: "${WORDPRESS_IMAGE:?set WORDPRESS_IMAGE to the built WordPress image}"

# Local verification must never exercise a published/remote GHCR image: build
# + load locally first (make build) and pass the local tag. Reject anything that
# looks like a registry reference or is absent from the local daemon.
require_local_image "$WORDPRESS_IMAGE"

TMPDIR_HOST="$(mktemp -d)"
WP_CLI_HOST="$TMPDIR_HOST/wp-cli.phar"

trap 'docker compose -f compose/wordpress.local.yaml down -v >/dev/null 2>&1 || true; rm -rf "$TMPDIR_HOST" 2>/dev/null || true' EXIT

wp_container() {
    $COMPOSE ps -q "$SERVICE"
}

# Copy the pinned wp-cli into the currently running app container.
install_wpcli() {
    [ -f "$WP_CLI_HOST" ] || {
        echo "== [verify] downloading wp-cli $WP_CLI_VERSION =="
        curl -fsSL -o "$WP_CLI_HOST" "$WP_CLI_URL"
        echo "$WP_CLI_SHA512  $WP_CLI_HOST" | sha512sum -c - >/dev/null
    }
    docker cp "$WP_CLI_HOST" "$(wp_container):/tmp/wp-cli.phar"
}

# Run a wp-cli command inside the app container as root (install/verify only).
wp() {
    docker exec "$(wp_container)" php /tmp/wp-cli.phar --path=/var/www/html "$@"
}

wait_app() {
    echo "== [verify] waiting for /healthz on :${HOST_PORT} =="
    wait_http_auth "$SITE_URL/healthz" 200 "$AUTH_USER" "$AUTH_PASS" 90 3
}

echo "== [verify] starting stack (MariaDB + WordPress) =="
$COMPOSE up -d
wait_app
pass "/healthz returns 200 (PHP-backed, pre-install)"

echo "== [verify] fresh shadowing volume: uploads unseeded (pre-install) =="
# Assert BEFORE wp install: WordPress itself creates dated year/month dirs
# under uploads during install, so emptiness must be proven before any WP write.
uploads="$(docker exec "$(wp_container)" sh -c 'ls -A /var/www/html/wp-content/uploads')"
[ -z "$uploads" ] || die "uploads should be unseeded on fresh volume, found: $uploads"
pass "uploads starts empty (never seeded by the image)"

install_wpcli

echo "== [verify] installing WordPress =="
wp core is-installed >/dev/null 2>&1 && installed=1 || installed=0
if [ "$installed" = "0" ]; then
    wp core install --url="$SITE_URL" --title="Pinner Test" \
        --admin_user=admin --admin_password='adminpass' \
        --admin_email=admin@example.com --skip-email --allow-root >/dev/null
fi
wp core is-installed --allow-root
pass "WordPress installed via wp-cli"

echo "== [verify] fresh-volume default theme + bundled plugins =="
themes="$(docker exec "$(wp_container)" sh -c 'ls /var/www/html/wp-content/themes')"
echo "$themes" | grep -q twentytwentyfive \
    || die "default theme twentytwentyfive missing on fresh volume: $themes"
pass "default theme twentytwentyfive present on fresh shadowing volume"
echo "$themes" | grep -q twentytwentyfour \
    || die "bundled theme twentytwentyfour missing"
pass "bundled theme twentytwentyfour present"

plugins="$(docker exec "$(wp_container)" sh -c 'ls /var/www/html/wp-content/plugins')"
echo "$plugins" | grep -q akismet || die "bundled plugin akismet missing: $plugins"
pass "bundled plugin akismet present"

wp theme activate twentytwentyfive --allow-root >/dev/null
pass "default theme activated"

echo "== [verify] seeding test artifacts (user content) =="
docker exec "$(wp_container)" sh -c \
    'printf "plugin-marker-content" > /var/www/html/wp-content/plugins/pinner-verify-plugin.txt'
docker exec "$(wp_container)" sh -c \
    'printf "theme-marker-content"  > /var/www/html/wp-content/themes/pinner-verify-theme.txt'
docker exec "$(wp_container)" sh -c \
    'printf "upload-marker-content" > /var/www/html/wp-content/uploads/pinner-verify-upload.txt'
docker exec "$(wp_container)" sh -c \
    'printf "ephemeral-core" > /var/www/html/.core-marker.txt'
pass "wrote plugin/theme/upload artifacts + ephemeral core marker"

echo "== [verify] recreating app container (volumes persist) =="
$COMPOSE up -d --force-recreate "$SERVICE"
wait_app
install_wpcli

echo "== [verify] ephemeral core gone, persistent content survived =="
docker exec "$(wp_container)" sh -c 'test ! -e /var/www/html/.core-marker.txt' \
    && pass "ephemeral core marker gone after recreation" \
    || die "ephemeral marker survived (core was expected ephemeral)"
docker exec "$(wp_container)" sh -c 'test -f /var/www/html/wp-config.php' \
    && pass "wp-config.php regenerated (ephemeral)" \
    || die "wp-config.php missing after recreation"

c_plugin="$(docker exec "$(wp_container)" sh -c 'cat /var/www/html/wp-content/plugins/pinner-verify-plugin.txt')"
[ "$c_plugin" = "plugin-marker-content" ] || die "plugin artifact overwritten"
pass "user plugin content survived and was not overwritten"

c_theme="$(docker exec "$(wp_container)" sh -c 'cat /var/www/html/wp-content/themes/pinner-verify-theme.txt')"
[ "$c_theme" = "theme-marker-content" ] || die "theme artifact overwritten"
pass "user theme content survived and was not overwritten"

c_upload="$(docker exec "$(wp_container)" sh -c 'cat /var/www/html/wp-content/uploads/pinner-verify-upload.txt')"
[ "$c_upload" = "upload-marker-content" ] || die "upload artifact overwritten"
pass "user upload survived and was not overwritten"

docker exec "$(wp_container)" sh -c 'test -d /var/www/html/wp-content/themes/twentytwentyfive' \
    && pass "default theme still present after recreation" \
    || die "default theme missing after recreation"

echo "== [verify] deleted plugin is not resurrected (marker honoured) =="
docker exec "$(wp_container)" sh -c 'rm /var/www/html/wp-content/plugins/hello.php'
$COMPOSE up -d --force-recreate "$SERVICE"
wait_app
docker exec "$(wp_container)" sh -c 'test ! -e /var/www/html/wp-content/plugins/hello.php' \
    && pass "deleted bundled plugin was not resurrected" \
    || die "deleted plugin came back (seeding should be one-time)"

echo "== [verify] runtime user writability + non-root =="
want="$(app_uid_of "$(wp_container)")"
out="$(docker exec -u "$want" "$(wp_container)" sh -c \
    'echo writable > /var/www/html/wp-content/uploads/.permtest; cat /var/www/html/wp-content/uploads/.permtest')"
[ "$out" = "writable" ] && pass "mounted uploads writable by runtime user (uid $want)" \
    || die "mounted dir not writable by runtime user: '$out'"

assert_pid1_nonroot "$(wp_container)" "$want"
assert_nonroot "$(wp_container)" "$want"

echo "== [verify] idempotence: second recreate does not re-seed =="
$COMPOSE restart "$SERVICE" >/dev/null
wait_app
docker exec "$(wp_container)" sh -c 'test -d /var/www/html/wp-content/themes/twentytwentyfive' \
    && pass "no re-seed corruption after restart (default theme intact)" \
    || die "default theme missing after restart"

echo "== [verify-wordpress] ALL CHECKS PASSED =="
