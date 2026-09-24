# wordpress

Pinner **WordPress** workspace image: WordPress served by Caddy on PHP-FPM,
built on the `php-caddy` base. Uses official WordPress conventions.

| Aspect | Value |
|---|---|
| Base | `php-caddy` (`php:8.5.10-fpm-bookworm` + Caddy `2.11.4`) |
| WordPress | `7.1` (archive sha256 verified) |
| WP-CLI | `2.12.0` (baked in, sha512 verified) |
| Cast plugin | latest `develop` tree snapshot, deps vendored at build (not checksum-pinned yet) |
| Immutable source | `/usr/src/wordpress` |
| Runtime docroot | `/var/www/html` (ephemeral) |
| Listen | `0.0.0.0:${PORT:-8080}` |
| Runtime user | `www-data` (non-root) |

## Version pins — single source of truth

The WordPress version/sha256, the WP-CLI version/sha512, and the Go builder
image (name + digest for the `workspace-init` CLI) live **only** in
`images/wordpress/versions.env` (the PHP/Caddy pins live in
`images/php-caddy/versions.env`). `docker-bake.hcl` injects them into the Docker
ARGs and OCI labels; the `Dockerfile` declares those ARGs **without hardcoded
literals**, so there is no second copy to drift. Bump by editing `versions.env`,
then run `make deps-verify` (which re-checks the WP-CLI phar checksum and asserts
bake forwards the same values) and rebuild.

## Persistence contract

Only these three paths are persistent (mounted):

```
/var/www/html/wp-content/themes
/var/www/html/wp-content/plugins
/var/www/html/wp-content/uploads
```

Everything else in `/var/www/html` — WordPress core, `wp-config.php`, caches,
runtime state — is **ephemeral** and recreated per container.

## Portal storage mounts (env contract)

The Pinner portal injects the three mounts as a zero-based, **contiguous**
env-var array. Indexes must be consecutive (`0`, `1`, `2`) and unique — a
repeated index collapses, and a gap at `0` drops the whole array (mounts are
silently ignored).

```text
PORTAL__SERVICE__IPFS__WORKSPACE__RUNTIME__STORAGE_0='{"name_suffix":"themes","mount_path":"/var/www/html/wp-content/themes"}'
PORTAL__SERVICE__IPFS__WORKSPACE__RUNTIME__STORAGE_1='{"name_suffix":"plugins","mount_path":"/var/www/html/wp-content/plugins"}'
PORTAL__SERVICE__IPFS__WORKSPACE__RUNTIME__STORAGE_2='{"name_suffix":"uploads","mount_path":"/var/www/html/wp-content/uploads"}'
```

The portal passes each `mount_path` through **unchanged**; it does not choose
or override the in-container path, so the image owns these paths. Keep the
expected paths (`/var/www/html/wp-content/...`) and the zero-based indexing
canonical — do not change them to accommodate a decode limitation.
Validation note: indexed array decoding is confirmed, but decoding each entry
as a nested JSON object into the portal's `WorkspaceStorageConfig` list should
be integration-tested before relying on it in production.

## Startup (`wp-init.sh`)

Runs as root (via the base `PINNER_INIT` hook) before privileges are dropped:

1. **Seed core** — copy immutable `/usr/src/wordpress` → ephemeral docroot
   (skipping `wp-content`).
2. **Fail closed on missing DB** — if `WORDPRESS_DB_HOST` is unset the init
   exits non-zero (a WordPress workspace without a DB is a real
   misconfiguration; we refuse to boot broken).
3. **Seed `themes` and `plugins`** from `/usr/src/wordpress/wp-content` onto the
   mounted volumes (copy-based, never symlinks), so the default theme, bundled
   plugins, and the platform-managed **cast** plugin appear on a brand-new
   shadowing volume.
4. **Copy `mu-plugins`** (the Cast guard) into the ephemeral `wp-content` on
   every boot — it is platform-owned code like core, not persistent content.
5. **Leave `uploads` unseeded** (user media only).
6. **Generate `wp-config.php`** with WP-CLI `wp config create` as `www-data`
   (mode **0600**, owner-only read; DB password + proxy/URL extra PHP travel on
   stdin, never argv).
7. **Automatic bootstrap** — wait (bounded) for the DB, then on first boot run
   `wp core install --url=$COOLIFY_URL` with the owner email (fetched from the
   portal by the baked-in `workspace-init` CLI) and the existing
   `WORKSPACE_AUTH_*` credentials; on every boot converge the admin password to
   the current `WORKSPACE_AUTH_PASSWORD` and converge the platform-managed
   **cast** plugin to active (real activation hooks). A DB that is merely down,
   or a portal that cannot supply the email, defers install to a later boot
   with a clear warning rather than inventing a bogus admin email.
8. **Ownership** — repair root-owned mount roots; only recursive-chown when the
   mount root is not already owned by `www-data`.

### `wp-config.php` generation (`wp config create`)

Uses the **WP-CLI baked into the image** (`/usr/local/bin/wp`, pinned) rather
than a custom generator:

- **Secret-safe** — the DB password travels on stdin via `--prompt=dbpass` (and
  the admin password via `--prompt=admin_password` on `wp core install`), so
  **no secret ever appears on `argv`, in process listings, or in logs**. WP-CLI
  runs as `www-data` via `setpriv`, never as root.
- **Mode 0600** — an empty `wp-config.php` is pre-created as `www-data` (0600)
  before the WP-CLI call and re-`chown`ed/`chmod`ed to 0600 `www-data`
  afterwards (owner-only read; never world-readable).
- **DB host/port** — a `:port` already on `WORDPRESS_DB_HOST` is honoured;
  `WORDPRESS_DB_PORT` is appended only when the host has no port.
- **Proxy/URL** — `COOLIFY_URL` (the public URL) sets `WP_HOME`/`WP_SITEURL`
  via `--extra-php` (single-quote-safe `var_export` literal for URL values); the
  standard `X-Forwarded-Proto`/`X-Forwarded-Host` HTTPS block is preserved.
- **`--skip-check`** lets config generation complete while the DB is still
  coming up; salts are generated fresh by WP-CLI. `WP_CACHE_KEY_SALT` is
  intentionally *not* set (the whole config is ephemeral, no persistent object
  cache).
- **Workspace lockdown** (baked in as hard `define()`s via `--extra-php`):
  - `DISALLOW_FILE_EDIT` — wp-admin can never edit the filesystem (plugin/theme
    editor is dead). Pieces of code that ARE managed (core, the `cast` plugin)
    come from the image; everything in `wp-content` stays out of the editor.
  - No `DISALLOW_FILE_MODS` — **installing and updating plugins through
    wp-admin stays available on purpose**; that is how the site manages its own
    plugin set alongside the image-provisioned ones (Cast).
  - `AUTOMATIC_UPDATER_DISABLED` / `WP_AUTO_UPDATE_CORE` — WordPress never
    updates itself out of band (its scheduled update hooks become no-ops that
    find nothing to do; outbound checks to api.wordpress.org remain harmless
    reads). Updates happen only when someone triggers them.
  - `DISABLE_WP_CRON` — cron is not triggered by web traffic; the supervised
    worker below ticks it instead.
- Config is **ephemeral**: regenerated every start.

### Background cron (`pinner-wp-cron.sh`, supervised WP-CLI worker)

With web cron disabled, the scheduler is driven by a third supervised child
(passed to the base supervisor via `ENV PINNER_SUPERVISED_CMD`):

- Every `WP_CRON_INTERVAL` (seconds, default **30**) it runs
  `wp --path=/var/www/html cron event run --due-now` — WP's own scheduler
  decides what is due; there is **no DIY system cron, no crontab, no schedule
  duplicated outside WordPress**.
- Transient conditions (DB still coming up, install deferred to a later boot)
  are warned on stderr and retried on the next tick — never fatal, so the
  worker cannot take an otherwise-healthy container down.
- Being a supervised child, an actual worker death fails the container
  (orchestrator restarts it), and `TERM`/`INT`/`QUIT` shut it down gracefully.

### Automatic bootstrap (`wp core install` + password converge)

- **First boot** — after the bounded DB wait, `workspace-init` (the baked-in Go
  CLI) exchanges `PORTAL_API_KEY` for a login-purpose JWT via `POST /api/auth/key`,
  then reads the owner email via `GET /api/account`; `wp-init.sh` runs
  `wp core install --url=$COOLIFY_URL --admin_email=$email --skip-email` with the
  existing `WORKSPACE_AUTH_USERNAME`/`PASSWORD`.
- **Every boot** — `converge_admin_password` updates the WordPress admin
  password to the current `WORKSPACE_AUTH_PASSWORD`, so portal credential
  rotation takes effect on redeploy.
- **Safe fallback** — if the DB is down past the bound, or the portal cannot
  supply the owner email, install is **deferred to the next boot with a warning**
  (never an invented email). The container still starts healthy (`/healthz` is
  WP-independent).

### Seeding policy

| Volume state | Behaviour |
|---|---|
| Fresh/empty | Seed bundled `themes`/`plugins` content |
| `.seeded` marker present | Do nothing |
| `.seeding` marker (interrupted by us) | Finish the copy safely |
| Non-empty, no marker | Preserve contents; never overwrite |
| `uploads` | Always empty from image; only ensure writable |

Initialization is serialized with `flock` on the shared volume and idempotent:
a bounced container or concurrent first boot will not re-seed, and user edits
to plugins/themes survive recreation.

## Platform-managed Cast plugin

The **Cast** plugin is workspace infrastructure (like `wp-config.php` — not
user content), so delivery is image-owned:

- The image **bakes the latest `develop` tree snapshot** of
  [`LumeWeb/cast`](https://github.com/LumeWeb/cast) (GitHub codeload tarball;
  deliberately not checksum-pinned yet) with runtime Composer dependencies
  vendored at build time, under `/usr/src/wordpress/wp-content/plugins/cast`.
- One-time volume seeding delivers it on fresh volumes. On **already-seeded
  volumes** a boot-time reconciler (`reconcile_cast()` in `wp-init.sh`)
  converges only `wp-content/plugins/cast` to the image-baked copy on **every
  boot** — an image upgrade or rollback delivers the new/older Cast to
  *existing* workspaces on their next restart. All other plugins stay
  user-owned (never clobbered); the replaced copy is archived as
  `plugins/.cast.bak-<epoch>` (dot-prefixed so WordPress's plugin scan
  ignores it; one backup retained) for manual rollback.
- A **Cast guard MU plugin** (`mu-plugins/cast-guard.php`, copied into the
  ephemeral `wp-content/mu-plugins` every boot) re-adds `cast/cast.php` to the
  active plugins on every read (only while the plugin's files exist, so a
  transiently absent directory never gets a phantom active entry) and removes
  the admin Deactivate action — the plugin cannot be turned off. Startup
  convergence (`wp plugin activate cast`) only performs the real one-time
  activation transition (schema install, rewrite flush).

## Environment

| Variable | Purpose |
|---|---|
| `WORDPRESS_DB_HOST` | DB host |
| `WORDPRESS_DB_PORT` | DB port (joined into `DB_HOST`) |
| `WORDPRESS_DB_NAME` | Database name |
| `WORDPRESS_DB_USER` | DB user |
| `WORDPRESS_DB_PASSWORD` | DB password (secret) |
| `WORDPRESS_TABLE_PREFIX` | Table prefix (default `wp_`) |
| `COOLIFY_URL` | Public URL → `WP_HOME`/`WP_SITEURL` and `wp core install --url` |
| `PORTAL_API_URL` | Portal API base URL (used by `workspace-init` to fetch the owner email) |
| `PORTAL_API_KEY` | Portal workspace API key (secret, used by `workspace-init`) |
| `WORKSPACE_AUTH_USERNAME` | HTTP Basic Auth username **and** bootstrap WordPress admin user (secret, enforced by the base Caddy) |
| `WORKSPACE_AUTH_PASSWORD` | HTTP Basic Auth password **and** bootstrap WordPress admin password, converged every boot (secret, enforced by the base Caddy) |
| `WP_SITE_TITLE` | WordPress site title passed to `wp core install` (default `Pinner Workspace`) |
| `WP_DB_WAIT_TRIES` / `WP_DB_WAIT_INTERVAL` | Bounded DB-wait retries / sleep seconds (defaults `90` / `2`) |
| `PORT` | HTTP listen port (default `8080`) |

No numeric workspace-ID env is consumed: the container identifies itself to
the portal via `PORTAL_API_KEY` / `COOLIFY_URL`.

## HTTP Basic Auth

Public HTTP Basic Auth is enforced **by the image's Caddy layer** from the
`WORKSPACE_AUTH_USERNAME` / `WORKSPACE_AUTH_PASSWORD` secret env vars injected
by the portal (portal-plugin-ipfs PR #1031) — it is no longer the Coolify
proxy's responsibility. All requests with a public-range resolved client IP
require valid credentials (`401` otherwise) — including every request the
Coolify proxy forwards for a public client; loopback requests (client IP
`127.0.0.1` / `::1`) and private-network clients bypass auth so the container's
Docker health check of `/healthz` and in-deployment probes (e.g. Cast) pass.
The bypass resolves the client IP via Caddy's `client_ip` through
`trusted_proxies`: a public-range peer's spoofed `X-Forwarded-For` /
`X-Real-IP` is ignored (untrusted peer). Missing credentials fail the
container closed. See [`images/php-caddy/README.md`](../php-caddy/README.md).

## Security trade-off (privilege drop)

The entrypoint **must start as root** because Coolify/Docker named volumes are
commonly mounted `root:root`; only root can chown them and seed fresh volumes
that would otherwise shadow the image's bundled themes/plugins. To minimize the
blast radius:

- The root phase is short and does **only** mount/core prep.
- It permanently drops to `www-data` via `setpriv` before Caddy/PHP-FPM start;
  there is no path back to root, and no `setuid` helpers are installed.
- Application processes are non-root, so a PHP/Caddy compromise does not grant
  host or volume-level root.

The trade-off: one root shell exists transiently at first boot. If the runtime
must never run root, an alternative (not selected) is pre-chowning volumes
out-of-band in the orchestrator, which adds deployment coupling and still needs
to run as root somewhere.

## Verification

```sh
make verify-wordpress
```

Proves PHP-backed health, the image's **automatic first-boot install** (owner
email from a mock portal + `COOLIFY_URL`), **per-boot admin password rotation**,
fresh-volume default theme, persistence across container recreation, ephemeral
core, non-overwrite of user content, runtime-user writability, and non-root
final processes. Verification uses the WP-CLI and `workspace-init` **baked into
the image** — no external downloads.
