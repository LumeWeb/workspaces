#!/bin/bash
set -euo pipefail

# Privileged WordPress startup hook, executed by the php-caddy base entrypoint
# as ROOT, before it drops to www-data and starts Caddy + PHP-FPM.
#
# Responsibilities (in order):
#   1. Copy WordPress core from the immutable /usr/src/wordpress into the
#      ephemeral /var/www/html docroot (skipping wp-content, handled below).
#   2. Fail closed if WORDPRESS_DB_HOST is missing (a WP workspace without a DB
#      is a real misconfiguration; refuse to boot rather than run broken).
#   3. Seed persistent themes/plugins volumes from the immutable source,
#      despite the fact that the mounts shadow the same paths in the image.
#   3b. Converge the image-managed Cast plugin into the persistent plugins
#      volume (install/upgrade/rollback) on EVERY boot.
#   4. Copy the image-owned mu-plugins (Cast guard) into the ephemeral
#      wp-content/mu-plugins on EVERY boot (it is not a persistent mount).
#   5. Leave uploads unseeded (user media only).
#   6. Generate an ephemeral wp-config.php with WP-CLI `wp config create`
#      (mode 0600, owned by www-data).
#   7. Wait (bounded) for the DB to come up, then on first boot run
#      `wp core install` and on every boot converge the admin password to the
#      current WORKSPACE_AUTH_PASSWORD (credential rotation), and converge the
#      platform-managed Cast plugin to active (real activation hooks).
#   8. Fix ownership so www-data can write, INCLUDING the docroot core: WP's
#      get_filesystem_method() only picks 'direct' when wp-admin/includes/file.php
#      is owner-matched with the runtime user's temp-file probe; root-owned core
#      makes wp-admin plugin installs fall back to FTP and fail closed.
#
# This whole block must run as root: Docker/Coolify named volumes can be mounted
# root:root, and a fresh mount shadows the image content at /var/www/html/wp-content/*.
#
# Security notes:
#   - All WP-CLI commands run as www-data (via setpriv), never as root, and are
#     invoked with --prompt so the DB/admin secrets travel on stdin, NOT argv,
#     and are never echoed or logged.
#   - wp-config.php is written mode 0600 and owned by www-data (never
#     world-readable).
#   - Missing DB host fails the container closed (safe). A DB that is merely
#     *down* within the bounded wait, or a portal that cannot supply the owner
#     email, does NOT block a healthy start: install is deferred to a later boot
#     with a clear warning rather than inventing a bogus admin email.

APP_USER=www-data
APP_UID="$(id -u "$APP_USER")"

DOCROOT=/var/www/html
SRC=/usr/src/wordpress
WP_CONTENT="$DOCROOT/wp-content"

# --user-friendly wait bounds (override via env for tests) ---------------------
WP_DB_WAIT_TRIES="${WP_DB_WAIT_TRIES:-90}"      # ~3 min total
WP_DB_WAIT_INTERVAL="${WP_DB_WAIT_INTERVAL:-2}"

# True when a directory contains no real (non-dotfile) entries. We ignore
# dotfiles so our own lock/marker files never make a fresh volume look
# user-populated.
is_empty() {
    [ -z "$(find "$1" -mindepth 1 -maxdepth 1 ! -name '.*' -print -quit)" ]
}

# Run a WP-CLI command as the unprivileged app user against the docroot.
# Works because wp-init runs as root but setpriv can drop to www-data mid-script.
#
# umask is a shell builtin (not an executable), so it cannot be passed to
# `env`. We therefore wrap the target in `sh -c`: set a strict 077 umask, then
# `exec` wp so stdin (the --prompt secrets / --extra-php piped in by callers)
# flows through untouched and the generated wp-config.php is created mode 0600.
run_wp() {
    setpriv --reuid="$APP_USER" --regid="$APP_USER" --init-groups \
        env HOME=/var/www \
        sh -c 'umask 077; p="$1"; shift; exec /usr/local/bin/wp --path="$p" "$@"' \
        _ "$DOCROOT" "$@"
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

# Require the DB host env. A WordPress workspace with no DB cannot function, so
# fail closed (mirrors the base's fail-closed WORKSPACE_AUTH_* behaviour) rather
# than booting an unconfigured site or silently writing a broken wp-config.
require_db_env() {
    if [ -z "${WORDPRESS_DB_HOST:-}" ]; then
        echo "ERROR: WORDPRESS_DB_HOST is required to bootstrap a WordPress workspace; failing closed." >&2
        exit 1
    fi
}

# Compose the DB_HOST value: honour a ":port" already on WORDPRESS_DB_HOST,
# otherwise append WORDPRESS_DB_PORT so the port is not doubled.
compose_db_host() {
    local h="${WORDPRESS_DB_HOST:-}"
    case "$h" in
        *:*) echo "$h" ;;
        *)
            if [ -n "${WORDPRESS_DB_PORT:-}" ]; then
                echo "$h:$WORDPRESS_DB_PORT"
            else
                echo "$h"
            fi
            ;;
    esac
}

# Generate the ephemeral wp-config.php with WP-CLI `wp config create`. Runs as
# www-data; the DB password travels on stdin via --prompt (never argv/logs) and
# the trusted-forwarded-proxy + WP_HOME/WP_SITEURL block is supplied as extra
# PHP via --extra-php (also on stdin). --skip-check lets config generation
# proceed while the DB is still coming up.
#
# Before the WP-CLI call we pre-create an empty wp-config.php owned by www-data
# so the runtime user always owns the file it must rewrite on later boots.
generate_wp_config() {
    # WP-CLI refuses to overwrite an existing wp-config.php without --force, and
    # the runtime user must be able to write it. Pre-create a private blank file
    # owned by www-data.
    : > "$DOCROOT/wp-config.php"
    chown "$APP_USER:$APP_USER" "$DOCROOT/wp-config.php"
    chmod 600 "$DOCROOT/wp-config.php"

    local dbhost url_export
    dbhost="$(compose_db_host)"
    # Single-quote-escaped PHP literal for COOLIFY_URL, so a URL containing a
    # quote/backslash cannot break out of the generated define().
    # set -u: guard COOLIFY_URL so an unset variable does not abort the script.
    url_export="$(COOLIFY_URL="${COOLIFY_URL:-}" php -r 'echo var_export(getenv("COOLIFY_URL"), true);')"

    # WP-CLI stdin semantics (verified): with `--prompt=dbpass` + a bare
    # `--extra-php` flag, wp's arg-prompt reads exactly ONE line from stdin for
    # the password, and `wp config create` then copies ALL remaining stdin as
    # the extra PHP. Feeding a combined stream lets the DB password travel on
    # stdin (never argv/logs) while the proxy/WP_HOME PHP is still passed.
    # IMPORTANT: feed this via the `{ ... }` group pipe below — never a heredoc
    # directly on the run_wp command line, which would replace the piped stdin.

    {
        # First stdin line -> --prompt=dbpass (DB password, NOT on argv).
        printf '%s\n' "${WORDPRESS_DB_PASSWORD:-}"
        # Remainder of stdin -> --extra-php (verbatim, before the final require):
        # preserve the trusted-forwarded-proxy HTTPS/host handling and set
        # WP_HOME/WP_SITEURL from COOLIFY_URL (the workspace's public URL).
        cat <<'PROXYEOF'
if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && 'https' === $_SERVER['HTTP_X_FORWARDED_PROTO'] ) {
    $_SERVER['HTTPS'] = 'on';
}
if ( isset( $_SERVER['HTTP_X_FORWARDED_HOST'] ) ) {
    $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
}
// Workspace lockdown: wp-admin can never EDIT the filesystem (plugin/theme
// editor is dead), but installing and updating plugins through wp-admin stays
// available on purpose (no DISALLOW_FILE_MODS) — that is how the site manages
// its own plugin set alongside the image-provisioned ones. Automatic
// (out-of-band) WordPress/plugin updates remain off: installs and updates only
// ever happen when someone triggers them.
define( 'DISALLOW_FILE_EDIT', true );
define( 'AUTOMATIC_UPDATER_DISABLED', true );
define( 'WP_AUTO_UPDATE_CORE', false );
// WP cron must not fire from web traffic: a supervised worker drives it via
// WP-CLI every tick instead (see pinner-wp-cron.sh).
define( 'DISABLE_WP_CRON', true );
PROXYEOF
        if [ -n "${COOLIFY_URL:-}" ]; then
            printf 'define( %s, %s );\n' "'WP_HOME'" "$url_export"
            printf 'define( %s, %s );\n' "'WP_SITEURL'" "$url_export"
        fi
    } | run_wp config create --force --skip-check \
        --dbname="${WORDPRESS_DB_NAME:-}" \
        --dbuser="${WORDPRESS_DB_USER:-}" \
        --prompt=dbpass \
        --dbhost="$dbhost" \
        --dbprefix="${WORDPRESS_TABLE_PREFIX:-wp_}" \
        --dbcharset=utf8mb4 \
        --extra-php

    # Enforce the contract regardless of the writer's umask: 0600, www-data.
    chown "$APP_USER:$APP_USER" "$DOCROOT/wp-config.php"
    chmod 600 "$DOCROOT/wp-config.php"
}

# Bounded connectivity probe for the MySQL/MariaDB server. Credentials are read
# from the environment only (never argv); honours host[:port] semantics.
db_reachable() {
    php -r '
        $host = getenv("WORDPRESS_DB_HOST");
        $port = getenv("WORDPRESS_DB_PORT");
        $port = ($port === false || $port === "") ? "3306" : $port;
        if (strpos($host, ":") !== false) { list($host, $port) = explode(":", $host, 2); }
        mysqli_report(MYSQLI_REPORT_OFF);
        $m = @new mysqli($host, getenv("WORDPRESS_DB_USER"), (string)getenv("WORDPRESS_DB_PASSWORD"), getenv("WORDPRESS_DB_NAME"), (int)$port);
        exit($m->connect_errno ? 1 : 0);
    '
}

# Wait for the DB to become reachable, up to a bound, so we never hang the
# container's start forever. Returns non-zero if the bound is exceeded.
wait_for_db() {
    local tries="$WP_DB_WAIT_TRIES" interval="$WP_DB_WAIT_INTERVAL" i=0
    while [ "$i" -lt "$tries" ]; do
        if db_reachable; then
            return 0
        fi
        i=$((i + 1))
        sleep "$interval"
    done
    return 1
}

# Automatic first-boot `wp core install`. The owner email comes from the
# workspace-init CLI (which exchanges PORTAL_API_KEY for a login-purpose JWT via
# the portal and reads the account's email). If the portal is unreachable we do
# NOT invent an admin email: we defer install to a later boot with a clear
# warning (a healthy container that is just not yet installed).
auto_install() {
    if [ -z "${COOLIFY_URL:-}" ]; then
        echo "WARN: COOLIFY_URL unset; cannot determine site URL, skipping WordPress install this boot." >&2
        return 0
    fi

    local email=""
    if ! email="$(workspace-init)"; then
        echo "WARN: workspace-init could not fetch owner email from the portal; skipping automatic install this boot (will retry on next boot)." >&2
        return 0
    fi
    if [ -z "$email" ]; then
        echo "WARN: portal returned no owner email; skipping automatic install this boot (will retry on next boot)." >&2
        return 0
    fi

    echo "== [wp-init] installing WordPress (owner: $email, url: ${COOLIFY_URL}) =="
    # admin_password travels on stdin via --prompt (never argv/logs). A failed
    # install is not fatal to the boot: warn and defer to the next boot.
    if ! {
        printf '%s\n' "${WORKSPACE_AUTH_PASSWORD:-}"
    } | run_wp core install \
        --url="$COOLIFY_URL" \
        --title="${WP_SITE_TITLE:-Pinner Workspace}" \
        --admin_user="${WORKSPACE_AUTH_USERNAME:-admin}" \
        --admin_email="$email" \
        --skip-email \
        --prompt=admin_password; then
        echo "WARN: wp core install failed; site left uninstalled (will retry on next boot)." >&2
    fi
}

# Converge the WordPress admin password to the current WORKSPACE_AUTH_PASSWORD on
# every boot, so portal credential rotation takes effect even on an already
# installed site without manual intervention.
converge_admin_password() {
    if [ -z "${WORKSPACE_AUTH_USERNAME:-}" ] || [ -z "${WORKSPACE_AUTH_PASSWORD:-}" ]; then
        return 0
    fi
    # user_pass travels on stdin via --prompt. Failure (e.g. admin user renamed
    # out from under us) is non-fatal; the site keeps running.
    if ! {
        printf '%s\n' "$WORKSPACE_AUTH_PASSWORD"
    } | run_wp user update "$WORKSPACE_AUTH_USERNAME" --prompt=user_pass >/dev/null 2>&1; then
        echo "WARN: could not converge WordPress admin password for user '$WORKSPACE_AUTH_USERNAME'." >&2
    fi
}

# Converge the platform-managed Cast plugin to active on every boot (after the
# site is installed and WP-CLI can talk to the DB). This performs the REAL
# activation transition (CastActivator: schema install, rewrite flush) whenever
# the plugin was never activated; the baked-in cast-guard MU plugin then keeps
# it active read-side forever, so this is convergence, not enforcement.
activate_cast() {
    if ! run_wp core is-installed >/dev/null 2>&1; then
        return 0
    fi
    if ! run_wp plugin is-installed cast >/dev/null 2>&1; then
        echo "WARN: cast plugin files are missing from the plugins volume; cannot activate." >&2
        return 0
    fi
    if ! run_wp plugin activate cast >/dev/null 2>&1; then
        echo "WARN: could not activate the cast plugin (it stays guarded by the MU layer)." >&2
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

# Print "yes" when two directory trees contain byte-identical files (same
# relative paths, same contents), "no" otherwise. Content-based on purpose: it
# lets every boot skip an unnecessary replacement without trusting mtimes
# (cp -a preserves them, but wp-admin plugin edits do not keep them honest).
same_dir() {
    local l r
    l="$(cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum)"
    r="$(cd "$2" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum)"
    [ "$l" = "$r" ] && echo yes || echo no
}

# Converge the image-managed Cast plugin into the plugins volume. Cast is
# platform-managed like core: the volume's plugins/cast directory (absent,
# older baked copy, or user-drifted) is reconciled to the copy baked into the
# image on EVERY boot, so image upgrade and rollback both converge existing
# workspaces. This is delivery, not activation: activate_cast() below owns the
# real activation hooks. All other plugins (and wp-admin updates to them) stay
# under the volume's authority — only cast/ is ever touched here.
#
# The replaced copy is archived as plugins/.cast.bak-<epoch> (dot-prefixed so
# WordPress's get_plugins() scan ignores it; one backup is kept, the previous
# one retired first) for manual operator rollback.
#
# Lock + flock mirror seed_dir so concurrent/recreated boots on a shared
# volume cannot interleave a swap; the backup-move plus copy sequence keeps
# cast/ either fully old or fully new from PHP's point of view. If the swap
# is interrupted (container dies mid-copy), the next boot sees a different
# tree and converges again — the MU guard's files-presence gate keeps the
# site healthy in any transient absence.
reconcile_cast() {
    local src="$SRC/wp-content/plugins/cast"
    local dst="$WP_CONTENT/plugins/cast"

    # No baked Cast in this image (or build without it): nothing to converge.
    [ -d "$src" ] || return 0

    mkdir -p "$WP_CONTENT/plugins"
    exec 9>"$WP_CONTENT/plugins/.pinner-cast.lock"
    flock 9

    if [ -d "$dst" ] && [ "$(same_dir "$src" "$dst")" = yes ]; then
        flock -u 9
        exec 9>&-
        return 0
    fi

    rm -rf "$WP_CONTENT/plugins"/.cast.bak-[0-9]*
    if [ -d "$dst" ]; then
        mv "$dst" "$WP_CONTENT/plugins/.cast.bak-$(date +%s)"
    fi
    cp -a "$src"/. "$dst"/
    chown -R "$APP_USER:$APP_USER" "$dst"

    flock -u 9
    exec 9>&-
}

# Copy the image-owned mu-plugins into the ephemeral wp-content. mu-plugins is
# deliberately NOT a persistent mount (it is platform-owned code, like core),
# so this runs on every boot: an image update always replaces the guard on the
# next container start, and there is no user content here to ever preserve.
seed_mu_plugins() {
    local src="$SRC/wp-content/mu-plugins"
    local dst="$WP_CONTENT/mu-plugins"

    mkdir -p "$dst"
    cp -a "$src"/. "$dst"/
    chown -R "$APP_USER:$APP_USER" "$dst"
}

# uploads is never seeded; it only needs an existing, app-owned, writable dir.
prepare_uploads() {
    local dst="$WP_CONTENT/uploads"
    mkdir -p "$dst"
    if [ "$(stat -c %u "$dst")" != "$APP_UID" ]; then
        chown -R "$APP_USER:$APP_USER" "$dst"
    fi
}

# Chown the copied core to the app user. Comparison the OS cannot fake: WP's
# get_filesystem_method() returns 'direct' only if the owner of
# wp-admin/includes/file.php matches the freshly-written temp file's owner (the
# FPM user's uid). Root-owned core (cp -a from /usr/src) fails that comparison,
# so wp-admin plugin installs degrade to FTP/credentials and die with
# unable_to_connect_to_filesystem. Re-run every boot (seed_core is one-time per
# container, so seed-only chowning would miss recreated docroots) and
# deliberately does NOT recurse into wp-content, whose persistent mounts can be
# arbitrarily large (uploads).
fix_core_ownership() {
    chown "$APP_USER:$APP_USER" "$DOCROOT"
    chown -R "$APP_USER:$APP_USER" "$DOCROOT/wp-admin" "$DOCROOT/wp-includes"
    find "$DOCROOT" -maxdepth 1 -type f -exec chown "$APP_USER:$APP_USER" {} +
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
    fix_core_ownership
    require_db_env
    seed_dir themes
    seed_dir plugins
    reconcile_cast
    seed_mu_plugins
    prepare_uploads
    fix_wp_content_ownership
    generate_wp_config

    if wait_for_db; then
        if run_wp core is-installed >/dev/null 2>&1; then
            converge_admin_password
            activate_cast
        else
            auto_install
            activate_cast
        fi
    else
        echo "WARN: DB not reachable within ${WP_DB_WAIT_TRIES}s; skipping WordPress install this boot (will retry on next boot)." >&2
    fi
}

main "$@"
