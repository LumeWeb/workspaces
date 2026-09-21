<?php

/**
 * Plugin Name: Cast Guard
 * Description: Keeps the platform-managed Cast plugin active. Cast is workspace
 *              infrastructure provisioned by the image (like wp-config.php, not
 *              user content), so deactivation through the admin UI or direct
 *              option writes is enforced away on every request.
 * Version:     0.1.0
 * Author:      LumeWeb
 * License:     GPL-3.0-or-later
 */

declare(strict_types=1);

if (!defined('ABSPATH')) {
    exit;
}

const CAST_MAIN = 'cast/cast.php';

/*
 * WP 7.1 load-order compatibility shim: wp-settings.php loads (must-use and)
 * regular plugins BEFORE wp-includes/pluggable.php, and Cast calls wp_salt()
 * during its boot (SignaturePepper). Early-require pluggable for everything
 * after this point. This is safe: every pluggable function (wp_salt included)
 * is wrapped in function_exists(), so core's later plain `require` of the
 * file re-executes the same guarded definitions and redefines nothing.
 * Same-root fix belongs in Cast (resolve the pepper lazily, after pluggable
 * is loaded); this shim is removed once Cast is boot-safe on its own.
 */
if (!function_exists('wp_salt') && defined('ABSPATH') && defined('WPINC')) {
    require_once ABSPATH . WPINC . '/pluggable.php';
}

/*
 * Re-add Cast on EVERY read of the active_plugins option, regardless of how it
 * was last written (admin Deactivate, WP-CLI, REST). A read-time filter means
 * Cast is "active" again before the next request boots, so no separate boot run
 * is needed for enforcement — wp-init.sh's `wp plugin activate cast` only
 * performs the REAL one-time activation transition (schema install, rewrite
 * flush); it is not the enforcement mechanism.
 *
 * Not hooked: pre_option_active_plugins would also defeat legitimate core
 * logic that manages the option; return-value filtering after the read keeps
 * every other active plugin exactly as written.
 */
add_filter(
    'option_active_plugins',
    static function (array $plugins): array {
        return in_array(CAST_MAIN, $plugins, true)
            ? $plugins
            : array_merge($plugins, [CAST_MAIN]);
    }
);

/*
 * Network-active list force-on. This only ever fires in multisite contexts
 * (single-site workspaces never read active_sitewide_plugins), where Cast must
 * be enabled network-wide to be active. Cast registers no network-specific
 * lifecycle today, so a plain entry is sufficient.
 */
add_filter(
    'site_option_active_sitewide_plugins',
    static function (array $sitewide): array {
        if (!array_key_exists(CAST_MAIN, $sitewide)) {
            $sitewide[CAST_MAIN] = true;
        }

        return $sitewide;
    }
);

// Hide the Deactivate action so the admin UI matches reality: the toggle would
// appear to work (option write succeeds) but is overridden at the next read,
// which is worse than not offering it. This covers the site-admin Plugins
// screen; the network-admin equivalent is deliberately not hooked because
// network admin is not a supported surface yet.
add_filter(
    'plugin_action_links_' . CAST_MAIN,
    static function (array $actions): array {
        unset($actions['deactivate']);

        return $actions;
    }
);
