<?php
/**
 * Ephemeral wp-config.php generator for the Pinner WordPress image.
 *
 * Invoked by images/wordpress/wp-init.sh during the privileged startup phase
 * (as root, before the base entrypoint drops to www-data). It reads the
 * WORDPRESS_DB_* and PORTAL_WORKSPACE_URL environment variables directly and
 * writes $DOCROOT/wp-config.php atomically.
 *
 * Design constraints honoured here:
 *   - No shell interpolation and no secrets on argv/logs: every dynamic value
 *     (DB name/user/password, host:port, table prefix, public URL) travels only
 *     through the process environment and is emitted with PHP var_export(),
 *     which single-quote-escapes consistently so quotes, backslashes, dollar
 *     signs, newlines and non-ASCII bytes can never break out of (or into) the
 *     generated literal, regardless of their content.
 *   - No WP-CLI and no DB connection: generation never touches the database and
 *     works while the DB is still down at boot.
 *   - Atomic + private write: content is written to a temporary file created in
 *     the docroot (same filesystem so rename() is atomic) with mode 0600, then
 *     renamed over the target. On any failure the temp file is removed and the
 *     previous target (if any) is left untouched. The caller (wp-init.sh) then
 *     chowns the final 0600 file to www-data so it is readable by the app user
 *     and not world-readable.
 *   - Missing DB host is deliberately NOT fatal: it matches the previous
 *     behaviour of skipping generation with a warning so an image booted
 *     without DB config can still start (e.g. for diagnostics).
 *
 * Usage: php wp-config-generator.php [DOCROOT]
 *   DOCROOT defaults to /var/www/html.
 */

declare(strict_types=1);

function generator_fail(string $msg): void
{
    fwrite(STDERR, "ERROR: wp-config generator: " . $msg . "\n");
    exit(1);
}

function env_str(string $name, string $default = ''): string
{
    $v = getenv($name);
    return $v === false ? $default : $v;
}

/** Emit a define() line using var_export for the value (quote/escape safe). */
function define_var(string $name, string $value): string
{
    return 'define( ' . var_export($name, true) . ', ' . var_export($value, true) . " );\n";
}

/** Emit the salt-style define() used for the generated keys/salts. */
function define_salt(string $name, string $value): string
{
    return 'define(' . var_export($name, true) . ', ' . var_export($value, true) . ");\n";
}

$docroot = isset($argv[1]) && $argv[1] !== '' ? rtrim($argv[1], '/') : '/var/www/html';
$target  = $docroot . '/wp-config.php';

// --- Required-DB decision ---------------------------------------------------
// If the DB host is not configured we treat the image as intentionally not
// connected to a database: warn and skip generation (exit 0) instead of
// crashing startup. This preserves the image's previous behaviour.
$dbHostRaw = env_str('WORDPRESS_DB_HOST');
if ($dbHostRaw === '') {
    fwrite(STDERR, "WARN: WORDPRESS_DB_HOST unset; skipping wp-config.php generation.\n");
    exit(0);
}

// --- host[:port] ------------------------------------------------------------
// Honour a ":port" already present on WORDPRESS_DB_HOST; otherwise append
// WORDPRESS_DB_PORT so the port is not doubled (host:port + port -> ...:port:port).
$dbHost = $dbHostRaw;
if (strpos($dbHostRaw, ':') === false) {
    $port = env_str('WORDPRESS_DB_PORT');
    if ($port !== '') {
        $dbHost .= ':' . $port;
    }
}

// --- ephemeral salts --------------------------------------------------------
// Same set of keys/salts as before. WP_CACHE_KEY_SALT is intentionally NOT set
// (there is no persistent object cache and the whole config is ephemeral), which
// preserves the previous behaviour and avoids a per-boot key that would need to
// be stable across restarts to be useful.
$saltKeys = [
    'AUTH_KEY', 'SECURE_AUTH_KEY', 'LOGGED_IN_KEY', 'NONCE_KEY',
    'AUTH_SALT', 'SECURE_AUTH_SALT', 'LOGGED_IN_SALT', 'NONCE_SALT',
];
$salts = '';
foreach ($saltKeys as $key) {
    $salts .= define_salt($key, rtrim(base64_encode(random_bytes(48)), "=\r\n"));
}

$home = env_str('PORTAL_WORKSPACE_URL');

// --- assemble content (var_export for every interpolated value) --------------
$content = <<<'PHP'
<?php
/**
 * Auto-generated at container start by the Pinner WordPress init hook.
 * Ephemeral; regenerated on every start. Do not edit.
 */
PHP;
$content .= "\n";
$content .= define_var('DB_NAME', env_str('WORDPRESS_DB_NAME'));
$content .= define_var('DB_USER', env_str('WORDPRESS_DB_USER'));
$content .= define_var('DB_PASSWORD', env_str('WORDPRESS_DB_PASSWORD'));
$content .= define_var('DB_HOST', $dbHost);
$content .= <<<'PHP'
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

PHP;
$content .= $salts;
$content .= <<<'PHP'
define( 'WP_DEBUG', false );

PHP;
$content .= '$table_prefix = ' . var_export(env_str('WORDPRESS_TABLE_PREFIX', 'wp_'), true) . ";\n";
$content .= <<<'PHP'

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

PHP;
if ($home !== '') {
    $content .= define_var('WP_HOME', $home);
    $content .= define_var('WP_SITEURL', $home);
    $content .= "\n";
}
$content .= <<<'PHP'
if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
PHP;

// --- atomic private write ----------------------------------------------------
if (!is_dir($docroot) && !@mkdir($docroot, 0755, true) && !is_dir($docroot)) {
    generator_fail("cannot create docroot '$docroot'");
}
$tmp = $docroot . '/.wp-config.php.tmp.' . getmypid();
$fp  = @fopen($tmp, 'wb');
if ($fp === false) {
    generator_fail("cannot create temporary file '$tmp'");
}
// Explicit 0600 regardless of umask: secrets must never be world-readable.
@chmod($tmp, 0600);

$ok = true;
if (fwrite($fp, $content) === false) {
    $ok = false;
}
if (!fclose($fp)) {
    $ok = false;
}
if (!$ok) {
    @unlink($tmp);
    generator_fail("failed writing temporary file '$tmp'");
}
// Atomic replace: rename() over an existing target is atomic on the same
// filesystem, so no reader ever sees a half-written wp-config.php.
if (!@rename($tmp, $target)) {
    @unlink($tmp);
    generator_fail("cannot rename '$tmp' -> '$target'");
}
// Keep final mode 0600 (visible to www-data owner only, not world-readable).
@chmod($target, 0600);

exit(0);
