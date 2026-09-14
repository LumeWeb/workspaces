#!/bin/bash
set -euo pipefail

# Privileged WordPress startup hook, executed by the php-caddy base entrypoint
# as ROOT, before it drops to www-data and starts Caddy + PHP-FPM.
#
# Responsibilities (in order):
#   1. Copy WordPress core from the immutable /usr/src/wordpress into the
#      ephemeral /var/www/html docroot (skipping wp-content, handled below).
#   2. Generate an ephemeral wp-config.php from the WORDPRESS_DB_* env.
#   3. Seed persistent themes/plugins volumes from the immutable source,
#      despite the fact that the mounts shadow the same paths in the image.
#   4. Leave uploads unseeded (user media only).
#   5. Repair root-owned mounts and fix ownership so www-data can write.
#
# This whole block must run as root: Docker/Coolify named volumes can be mounted
# root:root, and a fresh mount shadows the image content at /var/www/html/wp-content/*.

APP_USER=www-data
APP_UID="$(id -u "$APP_USER")"

DOCROOT=/var/www/html
SRC=/usr/src/wordpress
WP_CONTENT="$DOCROOT/wp-content"

# Dedicated PHP generator for wp-config.php (installed by the Dockerfile and
# run here as root). It reads WORDPRESS_DB_*/PORTAL_WORKSPACE_URL straight from
# the environment, uses var_export for every value (no shell interpolation, no
# secrets in argv/logs) and writes atomically via a private 0600 temp file.
WP_CONFIG_GENERATOR=/usr/local/bin/wp-config-generator

# True when a directory contains no real (non-dotfile) entries. We ignore
# dotfiles so our own lock/marker files never make a fresh volume look
# user-populated.
is_empty() {
    [ -z "$(find "$1" -mindepth 1 -maxdepth 1 ! -name '.*' -print -quit)" ]
}

# Copy immutable WordPress core into the ephemeral docroot. Runs once per
# container (core is never a persistent mount), skipping wp-content whose
# persistent subdirectories are seeded separately under lock.
seed_core() {
    mkdir -p "$DOCROOT"
    if [ -e "$DOCROOT/wp-load.php" ]; then
        return 0
    fi
    for entry in "$SRC"/*; do
        [ "$(basename "$entry")" = "wp-content" ] && continue
        cp -a "$entry" "$DOCROOT"/
    done
    mkdir -p "$WP_CONTENT"
}

# Generate an ephemeral wp-config.php from the environment, regenerated every
# start (never persisted). All generation is delegated to a dedicated PHP
# script (WP_CONFIG_GENERATOR) that reads WORDPRESS_DB_* / PORTAL_WORKSPACE_URL
# directly, emits every value with var_export (safe PHP serialization — no shell
# interpolation, no secrets in argv/logs), and writes atomically via a private
# 0600 temp file it then renames into place. No WP-CLI and no DB connection are
# used, so this works while the DB is still down at boot.
#
# A missing WORDPRESS_DB_HOST is non-fatal: the generator warns and exits 0
# without creating the file, so an image booted without DB config still starts.
generate_wp_config() {
    php "$WP_CONFIG_GENERATOR" "$DOCROOT"

    # The generator wrote final mode 0600 owned by root; hand it to the app user
    # so www-data can read it as owner at runtime and it is not world-readable.
    # Only touches the file when generation actually produced one.
    if [ -e "$DOCROOT/wp-config.php" ]; then
        chown "$APP_USER:$APP_USER" "$DOCROOT/wp-config.php"
    fi
}

# One-time seed of a persistent mounted directory (themes or plugins) from the
# immutable image source. Copy-based, never symlinked, so the volume becomes
# authoritative and stays writable/upgradable by WordPress.
#
# Uses a pstream marker + flock so concurrent first boots and interrupted
# startups are handled deterministically:
#   - ".seeded"   -> fully initialized; do nothing
#   - ".seeding"  -> an earlier attempt of OURS was interrupted; finish it
#   - fresh empty -> seed from source
#   - non-empty, no marker -> pre-existing user data; preserve (never overwrite)
seed_dir() {
    local rel="$1"
    local src="$SRC/wp-content/$rel"
    local dst="$WP_CONTENT/$rel"
    local done_marker="$dst/.${rel}.seeded"
    local pending_marker="$dst/.${rel}.seeding"

    mkdir -p "$dst"

    # Serialize startup across any containers sharing this volume so concurrent
    # first boots cannot race each other's seed. Lock lives on the shared mount.
    exec 9>"$dst/.pinner-init.lock"
    flock 9

    local mode=0
    if [ ! -f "$done_marker" ]; then
        if [ -f "$pending_marker" ]; then
            mode=2               # our own interrupted copy; safe to finish
        elif is_empty "$dst"; then
            mode=1               # fresh, empty volume
        else
            echo "WARN: $dst is non-empty without a seed marker; preserving contents." >&2
        fi
    fi

    if [ "$mode" -gt 0 ]; then
        touch "$pending_marker"
        # idempotent copy; safe to re-run over a partial copy after interruption
        cp -a "$src"/. "$dst"/
        touch "$done_marker"     # written only after the copy fully succeeded
        rm -f "$pending_marker"
        mode=3                   # freshly seeded -> the tree needs ownership
    fi

    # Repair root-owned mount roots reliably, but avoid a recursive chown on
    # every boot once the mount root is already owned by the app user.
    if [ "$mode" -eq 3 ] || [ "$(stat -c %u "$dst")" != "$APP_UID" ]; then
        chown -R "$APP_USER:$APP_USER" "$dst"
    fi

    flock -u 9
    exec 9>&-
}

# uploads is never seeded; it only needs an existing, app-owned, writable dir.
prepare_uploads() {
    local dst="$WP_CONTENT/uploads"
    mkdir -p "$dst"
    if [ "$(stat -c %u "$dst")" != "$APP_UID" ]; then
        chown -R "$APP_USER:$APP_USER" "$dst"
    fi
}

# Make the ephemeral wp-content tree (and its non-mounted subdirs) writable by
# the app user without recursing into the (possibly large) mounted uploads dir.
fix_wp_content_ownership() {
    chown "$APP_USER:$APP_USER" "$WP_CONTENT"
    local d
    for d in cache upgrade languages; do
        mkdir -p "$WP_CONTENT/$d"
        chown "$APP_USER:$APP_USER" "$WP_CONTENT/$d"
        touch "$WP_CONTENT/$d/index.html"
    done
}

main() {
    seed_core
    generate_wp_config
    seed_dir themes
    seed_dir plugins
    prepare_uploads
    fix_wp_content_ownership
}

main "$@"
