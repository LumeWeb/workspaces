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

# Emit a PHP single-quoted string literal for an arbitrary value, escaping
# backslashes and single quotes so nothing can break out of (or into) the
# literal regardless of the value's content. Used for every interpolated value
# in wp-config.php so DB secrets and other env cannot inject PHP or shell code.
php_lit() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")"
}

# Generate an ephemeral wp-config.php from environment. Regenerated every start
# (never persisted). Uses the portal-provided public URL for home/site URL and
# honours X-Forwarded-* so HTTPS links stay correct behind the Coolify proxy.
#
# Dynamic values are emitted via printf with PHP-single-quote escaping (php_lit),
# so secrets containing shell metacharacters, single quotes, or backslashes are
# written literally and are never re-interpreted by the shell. Static content
# uses a quoted heredoc (no expansion at all).
generate_wp_config() {
    if [ -z "${WORDPRESS_DB_HOST:-}" ]; then
        echo "WARN: WORDPRESS_DB_HOST unset; skipping wp-config.php generation." >&2
        return 0
    fi

    # MariaDB host, with an optional port suffix. If WORDPRESS_DB_HOST already
    # carries a port ("host:port") honour it; otherwise append WORDPRESS_DB_PORT
    # so a port is not doubled up (host:port + port -> host:port:port).
    local dbhost="$WORDPRESS_DB_HOST"
    case "$dbhost" in
        *:*) : ;;
        *)  if [ -n "${WORDPRESS_DB_PORT:-}" ]; then
                dbhost="$dbhost:${WORDPRESS_DB_PORT}"
            fi ;;
    esac

    local salts=""
    local key
    local secret
    for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
               AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        secret="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
        salts="${salts}define('${key}', '${secret}');"$'\n'
    done

    local home="${PORTAL_WORKSPACE_URL:-}"

    {
        cat <<'EOF'
<?php
/**
 * Auto-generated at container start by the Pinner WordPress init hook.
 * Ephemeral; regenerated on every start. Do not edit.
 */
EOF
        printf "define( 'DB_NAME', %s );\n" "$(php_lit "${WORDPRESS_DB_NAME:-}")"
        printf "define( 'DB_USER', %s );\n" "$(php_lit "${WORDPRESS_DB_USER:-}")"
        printf "define( 'DB_PASSWORD', %s );\n" "$(php_lit "${WORDPRESS_DB_PASSWORD:-}")"
        printf "define( 'DB_HOST', %s );\n" "$(php_lit "$dbhost")"
        cat <<'EOF'
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

EOF
        printf '%s' "$salts"
        cat <<'EOF'
define( 'WP_DEBUG', false );

EOF
        printf "\$table_prefix = %s;\n" "$(php_lit "${WORDPRESS_TABLE_PREFIX:-wp_}")"

        cat <<'EOF'

/**
 * TLS is terminated by the upstream Coolify proxy; trust the forwarded scheme
 * and host so generated links and redirects stay HTTPS-correct even though the
 * container itself speaks plain HTTP on PORT.
 */
if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && 'https' === $_SERVER['HTTP_X_FORWARDED_PROTO'] ) {
    $_SERVER['HTTPS'] = 'on';
}
if ( isset( $_SERVER['HTTP_X_FORWARDED_HOST'] ) ) {
    $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
}

EOF
        if [ -n "$home" ]; then
            printf "define( 'WP_HOME', %s );\n" "$(php_lit "$home")"
            printf "define( 'WP_SITEURL', %s );\n" "$(php_lit "$home")"
        fi

        cat <<'EOF'

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
EOF
    } > "$DOCROOT/wp-config.php"
    chown "$APP_USER:$APP_USER" "$DOCROOT/wp-config.php"
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
