#!/bin/bash
# End-to-end local verification of the Pinner WordPress image with MariaDB.
#
# Proves: the image's automatic first-boot `wp core install` (owner email from
# the portal mock + COOLIFY_URL), per-boot admin password rotation, PHP-backed
# health, fresh-volume default theme, persistence of user content across
# container recreation, ephemeral core, non-overwrite of user content,
# deleted-plugin-not-resurrected, runtime-user writability, and non-root final
# processes. Also proves the workspace lockdown constants (no FS editing, no
# updates, no web cron) and that the supervised WP-CLI cron worker ticks WP's
# scheduler.
#
# Uses the WP-CLI + workspace-init CLI baked into the image (no external
# downloads).
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
# (must match compose/wordpress.local.yaml). Loopback and private-network peers
# bypass auth; requests through the published port carry a private-range peer
# (docker NAT), which is why host-side requests only ever use credentials.
AUTH_USER="localuser"
AUTH_PASS="localpass"

# The owner email returned by the mock portal (scripts/mock-portal.py); the
# baked-in workspace-init CLI must have fetched exactly this during install.
OWNER_EMAIL="owner@example.test"

# Credential-rotation test: the converge step must flip the WordPress admin
# password to this on a later boot.
ROTATE_PASS="rotated-pass"

: "${WORDPRESS_IMAGE:?set WORDPRESS_IMAGE to the built WordPress image}"

# Local verification must never exercise a published/remote GHCR image: build
# + load locally first (make build) and pass the local tag. Reject anything that
# looks like a registry reference or is absent from the local daemon.
require_local_image "$WORDPRESS_IMAGE"

trap 'docker compose -f compose/wordpress.local.yaml down -v >/dev/null 2>&1 || true' EXIT

wp_container() {
    $COMPOSE ps -q "$SERVICE"
}

# Run a wp-cli command inside the app container using the WP-CLI baked into the
# image (/usr/local/bin/wp). Verification runs as the container's default user;
# --allow-root keeps WP-CLI happy if that default is root.
wp() {
    docker exec "$(wp_container)" /usr/local/bin/wp --path=/var/www/html "$@"
}

wait_app() {
    echo "== [verify] waiting for /healthz on :${HOST_PORT} =="
    wait_http_auth "$SITE_URL/healthz" 200 "$AUTH_USER" "$AUTH_PASS" 90 3
}

echo "== [verify] starting stack (MariaDB + mock-portal + WordPress) =="
$COMPOSE up -d
wait_app
pass "/healthz returns 200 (PHP-backed)"

echo "== [verify] automatic first-boot install (image-side) =="
# The image's wp-init.sh should have run `wp core install` with the owner email
# fetched from the mock portal and the COOLIFY_URL as the site URL.
wp core is-installed --allow-root >/dev/null 2>&1 \
    && pass "WordPress auto-installed on first boot (image wp-init)" \
    || die "WordPress was NOT auto-installed by the image"

siteurl="$(wp option get siteurl --allow-root)"
[ "$siteurl" = "$SITE_URL" ] \
    && pass "siteurl set to COOLIFY_URL ($siteurl)" \
    || die "siteurl = '$siteurl', expected COOLIFY_URL '$SITE_URL'"

admin_email="$(wp user get "$AUTH_USER" --field=user_email --allow-root)"
[ "$admin_email" = "$OWNER_EMAIL" ] \
    && pass "admin '$AUTH_USER' registered with portal owner email ($admin_email)" \
    || die "admin email = '$admin_email', expected '$OWNER_EMAIL'"

echo "== [verify] workspace lockdown (no FS edits, no updates, no web cron) =="
# wp-init.sh bakes these constants into the generated wp-config.php; assert
# they are LIVE in the generated config (a mere Dockerfile string would pass
# an image-content grep but not protect the site).
for c in DISALLOW_FILE_EDIT DISALLOW_FILE_MODS AUTOMATIC_UPDATER_DISABLED DISABLE_WP_CRON; do
    val="$(wp config get "$c" --type=constant --allow-root)"
    [ "$val" = "1" ] || die "$c is not enabled in the generated wp-config.php (got: '$val')"
done
# WP_AUTO_UPDATE_CORE is defined as boolean false, which wp-cli renders empty;
# it must simply never enable auto core updates (incl. 'minor'/'major'/'beta').
upd="$(wp config get WP_AUTO_UPDATE_CORE --type=constant --allow-root)"
case "$upd" in
    1|true|minor|major|beta) die "WP_AUTO_UPDATE_CORE enables core updates (got: '$upd')" ;;
esac
pass "DISALLOW_FILE_EDIT/MODS, AUTOMATIC_UPDATER_DISABLED, WP_AUTO_UPDATE_CORE, DISABLE_WP_CRON all active"

echo "== [verify] supervised WP-CLI cron worker =="
# The worker is a third supervised child (PINNER_SUPERVISED_CMD) driving WP's
# own scheduler via `wp cron event run --due-now` every WP_CRON_INTERVAL. It
# must be alive, and must run as the non-root app user (the supervisor runs
# entirely post-privilege-drop).
wd="$(docker exec "$(wp_container)" sh -c 'for p in /proc/[0-9]*; do grep -aq pinner-wp-cron "$p/cmdline" 2>/dev/null && basename "$p" && break; done')"
[ -n "${wd:-}" ] || die "pinner-wp-cron worker process not running"
wd_uid="$(docker exec "$(wp_container)" sed -n "s/^Uid:\([[:space:]]*\)\([0-9]*\).*/\2/p" "/proc/$wd/status")"
wd_want="$(app_uid_of "$(wp_container)")"
[ "$wd_uid" = "$wd_want" ] || die "cron worker runs as uid $wd_uid, expected app uid $wd_want"
pass "cron worker (pinner-wp-cron) supervised and running as uid $wd_want"

# End-to-end proof the worker actually fires: schedule a single event due now;
# running a single event unschedules it, so the hook vanishing from WP's
# scheduler proves the worker ticked (a stale worker would never pick it up).
wp cron event schedule pinner-verify-cron now --allow-root >/dev/null
ran=0
i=0
while [ "$i" -lt 12 ]; do
    if ! wp cron event get pinner-verify-cron --allow-root >/dev/null 2>&1; then
        ran=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
[ "$ran" = "1" ] || die "scheduled due cron event never ran (worker is not ticking the scheduler)"
pass "cron worker ran a scheduled due-now event via WP-CLI"

echo "== [verify] fresh shadowing volume: uploads unseeded =="
# The image must never seed user media into uploads (wp-init only creates the
# mount root, see prepare_uploads). WordPress 7.x does create the current
# year/month upload subdirectory (e.g. 2026/09) at install, but those are EMPTY
# metadata dirs, not user content — so assert there are no files and no
# non-empty directories (i.e. no user media), rather than requiring the volume
# be strictly empty.
uploads_media="$(docker exec "$(wp_container)" sh -c 'find /var/www/html/wp-content/uploads -mindepth 1 ! -type d | wc -l')"
[ "$uploads_media" = "0" ] || die "uploads has $uploads_media user files/symlinks on a fresh volume (image must not seed uploads)"
pass "uploads empty of user media on fresh volume (never seeded by the image)"

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

echo "== [verify] per-boot admin password rotation =="
# Bump WORKSPACE_AUTH_PASSWORD (via compose interpolation) and recreate: the
# image must converge the WordPress admin password on the next boot. The new
# password is checked through wp_check_password() with the value carried on
# docker exec -e (env), never on argv. Note that the same env var drives Caddy's
# HTTP Basic Auth, so the health-wait must use the rotated password too.
AUTH_PASS="$ROTATE_PASS"
VERIFY_WP_PASS="$ROTATE_PASS" $COMPOSE up -d --force-recreate "$SERVICE"
wait_app
# The new password reaches wp_check_password() via docker exec -e (env), never
# on argv.
rot="$(docker exec -e WP_USER="$AUTH_USER" -e VERIFY_PASS="$ROTATE_PASS" "$(wp_container)" \
    /usr/local/bin/wp --path=/var/www/html --allow-root eval '
        $u = get_user_by("login", getenv("WP_USER"));
        if (!$u) { exit(2); }
        echo wp_check_password(getenv("VERIFY_PASS"), $u->user_pass, $u->ID) ? "match" : "nomatch";
    ' 2>/dev/null || true)"
[ "$rot" = "match" ] \
    && pass "admin password converged to new WORKSPACE_AUTH_PASSWORD" \
    || die "admin password NOT rotated: got '$rot'"

echo "== [verify] runtime user writability + non-root =="
want="$(app_uid_of "$(wp_container)")"
out="$(docker exec -u "$want" "$(wp_container)" sh -c \
    'echo writable > /var/www/html/wp-content/uploads/.permtest; cat /var/www/html/wp-content/uploads/.permtest')"
[ "$out" = "writable" ] && pass "mounted uploads writable by runtime user (uid $want)" \
    || die "mounted dir not writable by runtime user: '$out'"

assert_pid1_nonroot "$(wp_container)" "$want"
assert_nonroot "$(wp_container)" "$want"

echo "== [verify] idempotence: second restart does not re-seed =="
$COMPOSE restart "$SERVICE" >/dev/null
wait_app
docker exec "$(wp_container)" sh -c 'test -d /var/www/html/wp-content/themes/twentytwentyfive' \
    && pass "no re-seed corruption after restart (default theme intact)" \
    || die "default theme missing after restart"

echo "== [verify-wordpress] ALL CHECKS PASSED =="
