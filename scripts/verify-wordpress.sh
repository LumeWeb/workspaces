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

echo "== [verify] workspace lockdown (no FS edits, install/update allowed, no web cron) =="
# wp-init.sh bakes these constants into the generated wp-config.php; assert
# they are LIVE in the generated config (a mere Dockerfile string would pass
# an image-content grep but not protect the site). Plugin/theme editing stays
# impossible, but wp-admin plugin install/update must work (no DISALLOW_FILE_MODS).
for c in DISALLOW_FILE_EDIT AUTOMATIC_UPDATER_DISABLED DISABLE_WP_CRON; do
    val="$(wp config get "$c" --type=constant --allow-root)"
    [ "$val" = "1" ] || die "$c is not enabled in the generated wp-config.php (got: '$val')"
done
# WP_AUTO_UPDATE_CORE is defined as boolean false, which wp-cli renders empty;
# it must simply never enable auto core updates (incl. 'minor'/'major'/'beta').
upd="$(wp config get WP_AUTO_UPDATE_CORE --type=constant --allow-root)"
case "$upd" in
    1|true|minor|major|beta) die "WP_AUTO_UPDATE_CORE enables core updates (got: '$upd')" ;;
esac
# DISALLOW_FILE_MODS must be GONE ENTIRELY (the old image baked it): any
# definition, even 0, keeps WP's update/install machinery disabled.
if mods="$(wp config get DISALLOW_FILE_MODS --type=constant --allow-root 2>/dev/null)" && [ -n "$mods" ]; then
    die "DISALLOW_FILE_MODS is still defined (got: '$mods'); wp-admin plugin installs/updates would be blocked"
fi
pass "DISALLOW_FILE_EDIT, AUTOMATIC_UPDATER_DISABLED, WP_AUTO_UPDATE_CORE, DISABLE_WP_CRON active; DISALLOW_FILE_MODS absent"

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

echo "== [verify] supervised worker drives due Action Scheduler actions on the cron cadence =="
# The worker must run due Action Scheduler actions on its own WP_CRON_INTERVAL
# (5s here) cadence, NOT wait for Action Scheduler's own 1-minute WP-Cron queue
# event. Push that event 90s into the future so the legacy WP-Cron path CANNOT
# be what runs the action: anything executing it within the 40s deadline below
# proves the worker drives the Action Scheduler queue directly. (The baked
# WP-CLI has no `cron event reschedule`, so use WP's own cron API via `wp eval`,
# matching the args Action Scheduler registered the event with.) The push-out
# confirms its result inside one process and retries: a concurrent worker tick
# re-writing the cron option (lost update) could otherwise restore the old
# entry between an unschedule and a schedule.
delta="$(wp eval '
    $target = time() + 90;
    $t = false;
    for ( $i = 0; $i < 5; $i++ ) {
        $old = wp_next_scheduled( "action_scheduler_run_queue", array( "WP Cron" ) );
        if ( $old ) { wp_unschedule_event( $old, "action_scheduler_run_queue", array( "WP Cron" ) ); }
        wp_schedule_event( $target, "every_minute", "action_scheduler_run_queue", array( "WP Cron" ) );
        $t = wp_next_scheduled( "action_scheduler_run_queue", array( "WP Cron" ) );
        if ( $t === $target ) { break; }
    }
    echo (int) ( $t - time() );
' --allow-root)"
[ "$delta" -ge 60 ] || die "could not push the AS WP-Cron queue event out (next run in ${delta}s)"
# A temporary mu-plugin observes the test hook (mu-plugins are ephemeral and
# loaded on every request; the file is removed at the end of the check).
# The same mu-plugin captures the context argument the worker passes to
# action_scheduler_run_queue: that second argument is Action Scheduler's
# execution context / log label, and the worker must use the canonical 'WP
# Cron' context (the label AS's own WP-Cron queue runner uses) so log entries
# and batch semantics match the built-in runner.
docker exec "$(wp_container)" sh -c 'cat > /var/www/html/wp-content/mu-plugins/pinner-verify-as.php <<EOF
<?php
add_action( "pinner_verify_as_cron", function () {
    update_option( "pinner_verify_as_ran", time() );
} );
add_action( "action_scheduler_run_queue", function ( \$context = "" ) {
    update_option( "pinner_verify_as_context", (string) \$context );
} );
EOF'
wp eval 'ActionScheduler::factory()->async( "pinner_verify_as_cron" );' --allow-root
ran=0
i=0
while [ "$i" -lt 8 ]; do
    if [ -n "$(wp option get pinner_verify_as_ran --allow-root 2>/dev/null)" ]; then
        ran=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
docker exec "$(wp_container)" sh -c 'rm -f /var/www/html/wp-content/mu-plugins/pinner-verify-as.php'
[ "$ran" = "1" ] || die "due Action Scheduler action never ran within 40s while the AS WP-Cron queue event was pushed 90s out (worker is not driving the AS queue on its WP_CRON_INTERVAL cadence)"
# The worker's queue run must carry the canonical 'WP Cron' context (the hook
# payload captured above); a custom label would make AS log entries disagree
# with its built-in WP-Cron runner.
ctx="$(wp option get pinner_verify_as_context --allow-root 2>/dev/null || true)"
[ "$ctx" = "WP Cron" ] \
    || die "worker fired action_scheduler_run_queue with context '$ctx', expected the canonical 'WP Cron' context"
pass "worker fired action_scheduler_run_queue with the canonical 'WP Cron' context"
pass "worker ran a due Action Scheduler action within the 5s cron cadence (independent of the 1-minute AS WP-Cron event)"

echo "== [verify] AS queue-run concurrency guard is registered (no overlapping batches) =="
# This PR drives the AS queue every WP_CRON_INTERVAL on top of AS's own 1-min
# WP-Cron event and its async-request runner; all three converge on the
# action_scheduler_run_queue hook. AS 4.x serializes batches by claim count
# (concurrent_batches=1), which has a start-up TOCTOU window, so the image
# closes it with a GLOBAL lock guard (mu-plugin, loaded by every process). Prove
# the guard and its lock-duration config are actually REGISTERED in the running
# site (a mu-plugin that never loads would pass an image-content grep but not
# this), that the guard runs ahead of the runner, and that the queue-run lock
# duration is aligned with AS's per-batch time limit (the 30s batch) rather than
# left at the 60s async-runner default.
as_guard="$(wp eval '
    if ( ! class_exists( "ActionScheduler_QueueRunner" ) ) { echo "no-as"; exit; }
    $lock_filter = has_filter( "action_scheduler_lock_duration" );
    $guard       = has_action( "action_scheduler_run_queue", "pinner_as_queue_run_guard" );
    $runner      = has_action( "action_scheduler_run_queue", array( ActionScheduler_QueueRunner::instance(), "run" ) );
    $lock        = (int) apply_filters( "action_scheduler_lock_duration", 60, "pinner-queue-run" );
    $batch       = (int) apply_filters( "action_scheduler_queue_runner_time_limit", 30 );
    printf( "%s|%s|%s|%d|%d\n",
        $lock_filter ? "filter" : "none",
        $guard ? "guard" : "none",
        $runner ? "runner" : "none",
        $lock,
        $batch );
' --allow-root)"
echo "   as_guard=[$as_guard]"
IFS='|' read -r as_has_lock_filter as_has_guard as_has_runner as_lock_val as_batch_val <<< "$as_guard"
[ "$as_has_lock_filter" = "filter" ] || die "action_scheduler_lock_duration filter is NOT registered (AS concurrency-guard config missing): [$as_guard]"
[ "$as_has_guard" = "guard" ] || die "pinner_as_queue_run_guard is NOT registered on action_scheduler_run_queue (AS concurrency guard missing): [$as_guard]"
[ "$as_has_runner" = "runner" ] || die "AS queue runner is not registered on action_scheduler_run_queue (expected): [$as_guard]"
[ "$as_lock_val" -ge "$as_batch_val" ] 2>/dev/null || die "AS queue-run lock duration ($as_lock_val) is below the per-batch time limit ($as_batch_val); a slow batch could be overlapped"
[ "$as_lock_val" -ge 30 ] 2>/dev/null || die "AS queue-run lock duration ($as_lock_val) is below the 30s batch"
pass "AS concurrency guard registered: lock-duration filter present, queue-run guard ahead of the runner, lock aligned with the ${as_batch_val}s batch"

echo "== [verify] AS queue-run guard: losing run is suppressed per-process, not by callback removal =="
# Regression guard for a reviewed defect: the old losing branch called
# remove_action() from INSIDE do_action('action_scheduler_run_queue'), where
# the runner's callback is already snapshotted into the in-flight hook
# dispatch — so the removal never prevented the overlapping batch, and the
# lock was never released. The correction must zero the CURRENT process's
# allowed concurrent batches through the real
# 'action_scheduler_queue_runner_concurrent_batches' filter (the runner's
# has_maximum_concurrent_batches() then bails: claim_count >= 0 is always
# true), leave the runner callback attached, and never release a lock the
# losing process did not acquire.
as_loss="$(wp eval '
    if ( ! class_exists( "ActionScheduler" ) ) { echo "no-as"; exit; }
    delete_option( "action_scheduler_lock_pinner-queue-run" );
    ActionScheduler::lock()->set( "pinner-queue-run" ); // we stake the lock first
    pinner_as_queue_run_guard();                          // this process therefore loses
    $allowed  = (int) apply_filters( "action_scheduler_queue_runner_concurrent_batches", 1 );
    $attached = has_action( "action_scheduler_run_queue", array( ActionScheduler_QueueRunner::instance(), "run" ) );
    $left     = get_option( "action_scheduler_lock_pinner-queue-run" );
    $held     = ( false !== $left && "" !== $left );
    printf( "%d|%s|%s\n", $allowed, $attached ? "attached" : "removed", $held ? "held" : "gone" );
' --allow-root)"
echo "   as_loss=[$as_loss]"
IFS='|' read -r as_loss_allowed as_loss_attached as_loss_held <<< "$as_loss"
[ "$as_loss_allowed" = "0" ] || die "losing process did NOT zero action_scheduler_queue_runner_concurrent_batches (got: ${as_loss_allowed}); an overlapping batch can still run"
[ "$as_loss_attached" = "attached" ] || die "queue-runner callback was removed (broken remove_action approach); suppression must be the per-process zero-batches filter"
[ "$as_loss_held" = "held" ] || die "losing process released a lock it did not acquire (lock state: ${as_loss_held})"
pass "losing run suppressed per-process (concurrent_batches=0), runner callback still attached, foreign lock untouched"

echo "== [verify] AS queue-run guard: owner releases its lock after the run; crash bounded by 30s =="
# A guarded run in a fresh process must acquire the lock, run the queue, and
# then delete its precise lock option + object-cache entry in a post-run hook,
# so the next queue run proceeds immediately instead of waiting out the lock
# duration. If the process dies mid-run, the un-released lock must still
# expire via the 30s lock-duration fallback (bounded, not stale-forever).
as_release="$(wp eval '
    if ( ! class_exists( "ActionScheduler" ) ) { echo "no-as"; exit; }
    delete_option( "action_scheduler_lock_pinner-queue-run" );
    do_action( "action_scheduler_run_queue", "WP Cron" ); // guarded run
    $left = get_option( "action_scheduler_lock_pinner-queue-run" );
    echo ( false === $left || "" === $left ) ? "released" : "leaked:" . $left;
' --allow-root)"
# A concurrent worker tick may have won the lock first; that owner releases
# it in its own post-run hook within seconds, so allow a short grace period.
i=0
while [ "$i" -lt 10 ] && [ "$as_release" != "released" ]; do
    sleep 2
    left="$(wp option get action_scheduler_lock_pinner-queue-run --allow-root 2>/dev/null || true)"
    [ -z "$left" ] && as_release="released"
    i=$((i + 1))
done
[ "$as_release" = "released" ] || die "queue-run lock not released after the guarded run (got: $as_release)"
pass "lock option deleted by the owner in a post-run hook after the guarded run"

as_crash="$(wp eval '
    if ( ! class_exists( "ActionScheduler" ) ) { echo "no-as"; exit; }
    delete_option( "action_scheduler_lock_pinner-queue-run" );
    ActionScheduler::lock()->set( "pinner-queue-run" ); // crash: no post-run release
    $parts = explode( "|", (string) get_option( "action_scheduler_lock_pinner-queue-run" ) );
    echo (int) ( end( $parts ) - time() );
' --allow-root)"
[ "$as_crash" -ge 28 ] 2>/dev/null && [ "$as_crash" -le 31 ] 2>/dev/null \
    || die "un-released (crashed) queue-run lock is not bounded by the 30s duration fallback (expires in ${as_crash}s)"
pass "crash backstop: an un-released lock expires via the 30s duration fallback (expires in ${as_crash}s)"

echo "== [verify] AS queue-run guard: post-run release is compare-and-delete (stale owner keeps the newer lock) =="
# A post-run release must delete ONLY the exact lock value THIS process staked.
# If our lock expired (crashed/slow run) and a second owner replaced it, our
# late release callback must leave the newer owner's lock — and its
# object-cache entries — in place. Simulated: this process acquires the lock
# through the real guard (owner A), the lock is aged past its 30s expiry, a
# second owner (B) replaces it, then A's post-run release hook fires.
# Retried while a concurrent worker tick wins the lock first (then this
# process is the losing side, not A, and the attempt is inconclusive).
as_cas=""
i=0
while [ -z "$as_cas" ] && [ "$i" -lt 4 ]; do
    as_cas="$(wp eval '
    if ( ! class_exists( "ActionScheduler" ) ) { echo "no-as"; exit; }
    global $wpdb;
    $key = "action_scheduler_lock_pinner-queue-run";
    // Read the lock row straight from the DB: the WP option caches
    // (per-option and bulk alloptions) go stale next to direct SQL writes
    // by AS, so cache-based reads would make this check inconclusive.
    $dbv = function () use ( $wpdb, $key ) {
        $v = $wpdb->get_var( $wpdb->prepare( "SELECT option_value FROM $wpdb->options WHERE option_name = %s", $key ) );
        return false === $v ? "NONE" : (string) $v;
    };
    delete_option( $key );
    wp_cache_delete( $key, "action_scheduler_locks" );
    pinner_as_queue_run_guard(); // owner A acquires (installs its release hook)
    if ( ! has_action( "action_scheduler_after_process_queue", "pinner_as_queue_release_lock" ) ) {
        echo "retry"; // a concurrent worker won the lock; this attempt is not owner A
        exit;
    }
    $a = $dbv();
    $exp = end( explode( "|", (string) $a ) );
    wp_cache_delete( $key, "action_scheduler_locks" ); // drop the AS object-cache copy of the live value
    update_option( $key, (int) $exp - 60 );            // age the lock past its 30s expiry
    sleep( 1 );                                        // ensure B stakes a distinct value
    if ( ! ActionScheduler::lock()->set( "pinner-queue-run" ) ) {
        echo "retry"; // a concurrent owner won; this attempt is inconclusive
        exit;
    }
    $b = $dbv(); // the newer owners exact lock value
    do_action( "action_scheduler_after_process_queue" ); // A finally finishes
    $left  = $dbv();
    $cache = wp_cache_get( $key, "action_scheduler_locks" );
    printf(
        "%s|%s|%s\n",
        md5( $b ), // fingerprint only: the raw value contains a pipe
        $left === $b ? "db:kept" : "db:lost",
        ( false !== $cache && (string) $cache === (string) $b ) ? "cache:kept" : "cache:lost"
    );
' --allow-root)"
    [ "$as_cas" = "retry" ] && as_cas=""
    i=$((i + 1))
done
echo "   as_cas=[$as_cas]"
IFS='|' read -r as_cas_b as_cas_db as_cas_cache <<< "$as_cas"
[ "$as_cas_db" = "db:kept" ] || die "stale owner's post-run release deleted the NEWER owner's lock (db: ${as_cas_db}, newer value: ${as_cas_b})"
[ "$as_cas_cache" = "cache:kept" ] || die "stale owner's post-run release invalidated the NEWER owner's lock cache entry (cache: ${as_cas_cache})"
pass "post-run release is compare-and-delete: a stale owner leaves the newer owner's lock + cache intact"

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

# The platform-managed Cast plugin must be seeded with the volume and active.
echo "$plugins" | grep -qx cast || die "platform-managed cast plugin missing: $plugins"
pass "platform-managed cast plugin present on fresh volume"

docker exec "$(wp_container)" sh -c 'test -f /var/www/html/wp-content/mu-plugins/cast-guard.php' \
    && pass "cast-guard MU plugin present" \
    || die "cast-guard MU plugin missing (force-on enforcement is dead)"

wp plugin is-active cast --allow-root \
    || die "cast plugin is not active on a fresh volume (cast guard / activate_cast failed)"
pass "cast plugin active on fresh volume"

# The activation transition must have actually RUN: a guard-only "active"
# state without CastActivator leaves no schema and no version marker — the
# exact regression where the publish pipeline then 500s on a missing table.
# `wp plugin is-active` alone PASSES via the guard's read filter and must
# never be trusted as proof of activation.
# NB: `wp db tables` lists core tables only; custom tables must be probed
# directly. The expected name is derived from the live $wpdb->prefix (the
# table prefix is configurable and not assumed to be the wp_ default).
prefix="$(wp eval 'global $wpdb; echo (string) $wpdb->prefix;' --allow-root)"
table="$(wp eval 'global $wpdb; echo (string) $wpdb->get_var( $wpdb->prepare( "SHOW TABLES LIKE %s", "{$wpdb->prefix}cast_export_items" ) );' --allow-root)"
[ "$table" = "${prefix}cast_export_items" ] \
    || die "cast plugin is active but ${prefix}cast_export_items was never installed (activation hook did not run)"
pass "cast export-items table installed on fresh volume"

cast_version="$(wp eval 'echo (string) get_option( "cast_version" );' --allow-root)"
[ -n "$cast_version" ] \
    || die "cast is active but the cast_version option was never set (activation hook did not run)"
pass "cast_version recorded ($cast_version)"

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

echo "== [verify] cast survives recreation and stays (force-)active =="
docker exec "$(wp_container)" sh -c 'test -d /var/www/html/wp-content/plugins/cast' \
    && pass "cast plugin survived recreation" \
    || die "cast plugin missing after recreation"
wp plugin is-active cast --allow-root \
    || die "cast plugin not active after recreation"
pass "cast plugin active after recreation"

echo "== [verify] activate_cast self-heals a DB whose cast schema was lost =="
# Simulates damaged/rolled-back state: plugin stays active in the option but
# the schema and version marker are gone. The per-boot REAL activation cycle
# (deactivate_plugins silent + activate_plugin under WP_INSTALLING, with the
# guard's force-on standing down) must reinstall the schema.
wp eval 'global $wpdb; $wpdb->query( "DROP TABLE IF EXISTS {$wpdb->prefix}cast_export_items" ); delete_option( "cast_version" );' --allow-root >/dev/null
$COMPOSE up -d --force-recreate "$SERVICE"
wait_app
table="$(wp eval 'global $wpdb; echo (string) $wpdb->get_var( $wpdb->prepare( "SHOW TABLES LIKE %s", "{$wpdb->prefix}cast_export_items" ) );' --allow-root)"
[ "$table" = "${prefix}cast_export_items" ] \
    || die "activate_cast did not self-heal a lost cast schema on the next boot"
pass "lost cast schema restored by next boot's real activation"

echo "== [verify] deleted plugin is not resurrected (marker honoured) =="
docker exec "$(wp_container)" sh -c 'rm /var/www/html/wp-content/plugins/hello.php'
$COMPOSE up -d --force-recreate "$SERVICE"
wait_app
docker exec "$(wp_container)" sh -c 'test ! -e /var/www/html/wp-content/plugins/hello.php' \
    && pass "deleted bundled plugin was not resurrected" \
    || die "deleted plugin came back (seeding should be one-time)"

echo "== [verify] cast guard is neutral while cast files are missing =="
# Files are deliberately removed WITHOUT deleting the option entry first:
# the guard's read filter must keep the phantom cast/cast.php entry out of
# active_plugins (validate_active_plugins churn) while its directory is
# absent, i.e. force-on is strictly gated on files presence. WP-CLI resolves
# a plugin operand by scanning the plugins directory, so the option is
# deactivated BEFORE the rm below — after deletion, "wp plugin ..." commands
# for cast fail without ever rewriting the persisted option.
wp plugin deactivate cast --allow-root >/dev/null
docker exec "$(wp_container)" sh -c 'rm -rf /var/www/html/wp-content/plugins/cast'
active_json="$(wp option get active_plugins --format=json --allow-root)"
echo "$active_json" | grep -q 'cast/cast.php' \
    && die "cast guard re-added a phantom active-plugins entry while cast files are missing: $active_json" \
    || pass "cast guard neutral while cast files are missing (option read: $active_json)"

echo "== [verify] boot reconcile restores cast from the image bake =="
# Recreate: reconcile_cast() converges the volume's cast dir from the image
# source and activate_cast() performs the real activation transition.
$COMPOSE up -d --force-recreate "$SERVICE"
wait_app
docker exec "$(wp_container)" sh -c 'test -f /var/www/html/wp-content/plugins/cast/cast.php' \
    && pass "cast restored on existing volume by boot reconcile" \
    || die "cast not restored by boot reconcile"
wp plugin is-active cast --allow-root \
    || die "cast not re-activated after reconcile restore"

echo "== [verify] boot reconcile converges a drifted cast copy =="
# A copy that diverged from the image bake (user edit, partial update) is
# replaced; the pre-swap copy is archived as plugins/.cast.bak-<epoch>
# (dot-prefixed so WordPress's get_plugins() scan never sees it).
docker exec "$(wp_container)" sh -c \
    'printf "\n// tampered\n" >> /var/www/html/wp-content/plugins/cast/cast.php'
$COMPOSE up -d --force-recreate "$SERVICE"
wait_app
docker exec "$(wp_container)" sh -c \
    'grep -q "// tampered" /var/www/html/wp-content/plugins/cast/cast.php' \
    && die "boot reconcile did not converge a drifted cast copy to the image bake" \
    || pass "drifted cast copy converged back to the image bake"

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

# WP only picks the 'direct' filesystem method when the runtime user OWNS the
# core files it compares against its temp-file probe; root-owned core silently
# breaks wp-admin plugin installs (unable_to_connect_to_filesystem).
core_owner="$(docker exec "$(wp_container)" stat -c %u /var/www/html/wp-admin/includes/file.php)"
[ "$core_owner" = "$want" ] \
    && pass "WordPress core owned by runtime user (uid $core_owner)" \
    || die "core not owned by runtime user (file.php uid: $core_owner, want: $want)"

assert_pid1_nonroot "$(wp_container)" "$want"
assert_nonroot "$(wp_container)" "$want"

echo "== [verify] idempotence: second restart does not re-seed =="
$COMPOSE restart "$SERVICE" >/dev/null
wait_app
docker exec "$(wp_container)" sh -c 'test -d /var/www/html/wp-content/themes/twentytwentyfive' \
    && pass "no re-seed corruption after restart (default theme intact)" \
    || die "default theme missing after restart"

echo "== [verify-wordpress] ALL CHECKS PASSED =="
