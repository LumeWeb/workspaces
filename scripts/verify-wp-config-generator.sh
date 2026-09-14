#!/bin/bash
# Focused verification of the PHP-based wp-config.php generator
# (images/wordpress/wp-config-generator.php) inside the built WordPress image.
#
# Runs the generator's unit checks in a throwaway root container (special-char
# password round-trip, exact host/port, URL/proxy settings, 0600 permissions,
# repeat generation/idempotence + no stale temp, missing-DB-env behaviour, and
# no secret in argv/output/logs), then asserts the REAL /var/www/html/wp-config.php
# produced by wp-init.sh is owned by www-data, mode 0600, and readable by
# www-data.
#
# Usage: WORDPRESS_IMAGE=<image> verify-wp-config-generator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

: "${WORDPRESS_IMAGE:?set WORDPRESS_IMAGE to the built WordPress image}"

# Local verification must never exercise a published/remote GHCR image: build
# + load locally first (make build) and pass the local tag. Reject anything that
# looks like a registry reference or is absent from the local daemon.
require_local_image "$WORDPRESS_IMAGE"

CID_NAME="pinner-wpcfg-verify-$$"
CID=""

cleanup() {
    if [ -n "$CID" ]; then
        docker stop "$CID" >/dev/null 2>&1 || true
        docker rm -f "$CID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "== [verify] starting throwaway WordPress container (root phase) =="
# DB + auth env so wp-init generates the real config and the base does not fail
# closed on missing WORKSPACE_AUTH_*. The main process stays alive (supervise).
CID="$(docker run -d --name "$CID_NAME" \
    -e PORT=8080 \
    -e WORDPRESS_DB_HOST=db \
    -e WORDPRESS_DB_PORT=3306 \
    -e WORDPRESS_DB_NAME=wp \
    -e WORDPRESS_DB_USER=wp \
    -e WORDPRESS_DB_PASSWORD=wp-pass \
    -e PORTAL_WORKSPACE_URL=https://example.test \
    -e WORKSPACE_AUTH_USERNAME=verify \
    -e WORKSPACE_AUTH_PASSWORD=verifypass \
    "$WORDPRESS_IMAGE")"

echo "== [verify] waiting for init to write + chown the real wp-config.php =="
i=0
ready=0
while [ "$i" -lt 60 ]; do
    if docker exec "$CID" sh -c 'test -f /var/www/html/wp-config.php' 2>/dev/null; then
        ready=1
        break
    fi
    i=$((i + 1))
    sleep 1
done
[ "$ready" = "1" ] || die "init never produced /var/www/html/wp-config.php"

echo "== [verify] real wp-config.php ownership/permissions (www-data, 0600) =="
cfg_uid="$(docker exec "$CID" id -u www-data)"
meta="$(docker exec "$CID" sh -c 'stat -c "%u:%g %a" /var/www/html/wp-config.php')"
owner="${meta%% *}"
mode="${meta##* }"
[ "$owner" = "$cfg_uid:$cfg_uid" ] \
    || die "wp-config.php owner '$owner' != www-data '$cfg_uid:$cfg_uid'"
[ "$mode" = "600" ] \
    || die "wp-config.php mode '$mode' != 0600 (not world-readable)"
docker exec -u "$cfg_uid" "$CID" sh -c 'cat /var/www/html/wp-config.php >/dev/null' \
    || die "wp-config.php is not readable by www-data (uid $cfg_uid)"
pass "real wp-config.php owned by www-data, mode 0600, readable by www-data"

echo "== [verify] DB password not leaked into startup logs =="
if docker logs "$CID" 2>&1 | grep -q 'wp-pass'; then
    die "DB password leaked into container logs"
fi
pass "DB password absent from startup logs"

echo "== [verify] generator unit checks (special chars, host/port, URL, perms, idempotence, missing-env) =="
TMPDIR_HOST="$(mktemp -d)"
trap 'cleanup; rm -rf "$TMPDIR_HOST"' EXIT

# Embed the PHP verification harness (quoted heredoc: no shell expansion).
cat > "$TMPDIR_HOST/wpcfg-verify.php" <<'WPEOF'
<?php
/**
 * In-container verification harness for images/wordpress/wp-config-generator.php.
 * Executed as root (docker exec default user) inside the built wordpress image.
 *
 * Usage: php wpcfg-verify.php <generator> <scratchRootParent>
 */
declare(strict_types=1);
error_reporting(E_ALL);
ini_set('display_errors', '1');

$generator = $argv[1];
$parent    = rtrim($argv[2], '/');
$fail      = 0;

function res(bool $ok, string $msg): void {
    global $fail;
    echo ($ok ? "PASS: " : "FAIL: ") . $msg . "\n";
    if (!$ok) {
        $fail = 1;
    }
}

/**
 * Run the generator as a subprocess with a controlled environment. Invocation
 * argv is fixed to [php, generator, docroot] — the secret is never on argv.
 */
function run_gen(string $gen, string $docroot, array $env, &$outbuf, &$code): void {
    $cmd = [PHP_BINARY, $gen, $docroot];
    $spec = [1 => ["pipe", "w"], 2 => ["pipe", "w"]];
    $proc = proc_open($cmd, $spec, $pipes, null, $env);
    $out = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    $err = stream_get_contents($pipes[2]);
    fclose($pipes[2]);
    $code = proc_close($proc);
    $outbuf = $out . $err;
}

function stub_wpsettings(string $docroot): void {
    if (!is_dir($docroot)) {
        @mkdir($docroot, 0775, true);
    }
    // wp-settings.php stub so the generated config's trailing require_once can
    // be included standalone by the round-trip check.
    file_put_contents($docroot . '/wp-settings.php', "<?php\n");
}

function base_env(): array {
    $env = [];
    foreach (['PATH', 'HOME', 'TMPDIR'] as $k) {
        $v = getenv($k);
        if ($v !== false) {
            $env[$k] = $v;
        }
    }
    return $env;
}

// p@$$w0rd ' \ " NL newline é 中  (quote, backslash, dollar, newline, non-ASCII)
$specialPass = "p@\x24\x24w0rd ' \\ \"\nnewline\xc3\xa9\xe4\xb8\xad";

/* ---- 1) special-char password round-trip + URL/proxy + 0600 ---------------- */
$doc = "$parent/sc1";
stub_wpsettings($doc);
$env = base_env();
$env['WORDPRESS_DB_HOST'] = 'db.coolify';
$env['WORDPRESS_DB_PORT'] = '3306';
$env['WORDPRESS_DB_NAME'] = "my;db'\" \\";
$env['WORDPRESS_DB_USER'] = "u\$er \\ ' \"";
$env['WORDPRESS_DB_PASSWORD'] = $specialPass;
$env['WORDPRESS_TABLE_PREFIX'] = 'wp_';
$env['PORTAL_WORKSPACE_URL'] = 'https://example.com/wp?x=1&y=2';
run_gen($generator, $doc, $env, $out, $code);
res($code === 0, "special-chars generation exits 0");
res(strpos($out, $specialPass) === false, "secret never echoed in generator output");
res(strpos(json_encode([PHP_BINARY, $generator, $doc]), $specialPass) === false, "secret never passed on argv");

$file = "$doc/wp-config.php";
$mode = substr(sprintf('%o', (fileperms($file) & 0777)), -3);
res($mode === '600', "generated wp-config.php mode is 0600 (not world-readable), got $mode");
res(glob("$doc/.wp-config.php.tmp.*") === [], "no stale temp file left after generation");

require $file; // defines DB_*, WP_*, $table_prefix, etc.
$checks = [
    'DB_NAME'     => "my;db'\" \\",
    'DB_USER'     => "u\$er \\ ' \"",
    'DB_PASSWORD' => $specialPass,
    'DB_HOST'     => 'db.coolify:3306',
    'WP_HOME'     => 'https://example.com/wp?x=1&y=2',
    'WP_SITEURL'  => 'https://example.com/wp?x=1&y=2',
];
foreach ($checks as $const => $want) {
    $got = defined($const) ? constant($const) : null;
    res($got === $want, "round-trip $const matches input exactly");
}
res($table_prefix === 'wp_', "round-trip \$table_prefix matches input");

$cfgText = file_get_contents($file);
res(strpos($cfgText, 'HTTP_X_FORWARDED_PROTO') !== false
    && strpos($cfgText, 'HTTP_X_FORWARDED_HOST') !== false
    && strpos($cfgText, "require_once ABSPATH . 'wp-settings.php';") !== false,
    "proxy (X-Forwarded-*) + ABSPATH/wp-settings blocks present");

/* ---- 2) exact host/port semantics ----------------------------------------- */
function host_of(string $file): string {
    $t = file_get_contents($file);
    preg_match("/define\( 'DB_HOST', (.*?) \);/s", $t, $m);
    return eval('return ' . $m[1] . ';');
}

// host already has :port -> never doubled even with DB_PORT set
$d = "$parent/sc2a";
stub_wpsettings($d);
$e = base_env();
$e['WORDPRESS_DB_HOST'] = 'db.coolify:3307';
$e['WORDPRESS_DB_PORT'] = '3306';
run_gen($generator, $d, $e, $o, $c);
res($c === 0 && host_of("$d/wp-config.php") === 'db.coolify:3307', "DB_HOST retains existing :port (not doubled)");

// host without port + DB_PORT -> host:port
$d = "$parent/sc2b";
stub_wpsettings($d);
$e = base_env();
$e['WORDPRESS_DB_HOST'] = 'db.coolify';
$e['WORDPRESS_DB_PORT'] = '3306';
run_gen($generator, $d, $e, $o, $c);
res($c === 0 && host_of("$d/wp-config.php") === 'db.coolify:3306', "DB_HOST appends DB_PORT when absent");

// host without port, no DB_PORT -> host only
$d = "$parent/sc2c";
stub_wpsettings($d);
$e = base_env();
$e['WORDPRESS_DB_HOST'] = 'db.coolify';
unset($e['WORDPRESS_DB_PORT']);
run_gen($generator, $d, $e, $o, $c);
res($c === 0 && host_of("$d/wp-config.php") === 'db.coolify', "DB_HOST stays host-only with no port");

/* ---- 3) URL absent -> no WP_HOME/WP_SITEURL defines ------------------------- */
$d = "$parent/sc3";
stub_wpsettings($d);
$e = base_env();
$e['WORDPRESS_DB_HOST'] = 'db';
unset($e['PORTAL_WORKSPACE_URL']);
run_gen($generator, $d, $e, $o, $c);
$t3 = file_get_contents("$d/wp-config.php");
res($c === 0 && strpos($t3, 'WP_HOME') === false, "WP_HOME omitted when PORTAL_WORKSPACE_URL unset");

/* ---- 4) idempotence / repeat generation ------------------------------------ */
$d = "$parent/sc4";
stub_wpsettings($d);
$e = base_env();
$e['WORDPRESS_DB_HOST'] = 'db';
$e['WORDPRESS_DB_PASSWORD'] = 'secret';
run_gen($generator, $d, $e, $o1, $c1);
run_gen($generator, $d, $e, $o2, $c2);
res($c1 === 0 && $c2 === 0, "repeat generation succeeds (idempotence)");
res(glob("$d/.wp-config.php.tmp.*") === [], "no stale temp file after repeat generation");

/* ---- 5) missing required DB env ------------------------------------------- */
$d = "$parent/sc5";
stub_wpsettings($d);
$e = base_env();
unset($e['WORDPRESS_DB_HOST']);
run_gen($generator, $d, $e, $o, $c);
res($c === 0, "missing WORDPRESS_DB_HOST exits 0 (non-fatal)");
res(!file_exists("$d/wp-config.php"), "missing WORDPRESS_DB_HOST skips file creation");
res(stripos($o, 'WARN') !== false, "missing WORDPRESS_DB_HOST prints a warning, not a secret");
res(glob("$d/.wp-config.php.tmp.*") === [], "no stale temp file on skipped generation");

echo $fail ? "=== wp-config-generator: CHECKS FAILED ===\n" : "=== wp-config-generator: ALL CHECKS PASSED ===\n";
exit($fail);
WPEOF

docker cp "$TMPDIR_HOST/wpcfg-verify.php" "$CID:/tmp/wpcfg-verify.php"

set +e
hout="$(docker exec "$CID" php /tmp/wpcfg-verify.php /usr/local/bin/wp-config-generator /tmp/wcfg 2>&1)"
hcode=$?
set -e
echo "$hout"
if [ "$hcode" -ne 0 ]; then
    die "wp-config generator harness failed (exit $hcode)"
fi

echo "== [verify-wp-config-generator] ALL CHECKS PASSED =="
