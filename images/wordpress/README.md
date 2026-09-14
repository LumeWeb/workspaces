# wordpress

Pinner **WordPress** workspace image: WordPress served by Caddy on PHP-FPM,
built on the `php-caddy` base. Uses official WordPress conventions.

| Aspect | Value |
|---|---|
| Base | `php-caddy` (`php:8.5.10-fpm-bookworm` + Caddy `2.11.4`) |
| WordPress | `7.1` (archive sha256 verified) |
| Immutable source | `/usr/src/wordpress` |
| Runtime docroot | `/var/www/html` (ephemeral) |
| Listen | `0.0.0.0:${PORT:-8080}` |
| Runtime user | `www-data` (non-root) |

## Version pins — single source of truth

The WordPress version/sha256 live **only** in `images/wordpress/versions.env`
(the PHP/Caddy pins live in `images/php-caddy/versions.env`). `docker-bake.hcl`
injects them into the Docker ARGs and OCI labels; the `Dockerfile` declares those
ARGs **without hardcoded literals**, so there is no second copy to drift. Bump by
editing `versions.env`, then run `make deps-verify` (which asserts bake forwards
the same values) and rebuild.

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
2. **Generate `wp-config.php`** from `WORDPRESS_DB_*` + `PORTAL_WORKSPACE_URL`,
   honouring `X-Forwarded-*` for HTTPS-correct links behind the Coolify proxy.
3. **Seed `themes` and `plugins`** from `/usr/src/wordpress/wp-content` onto the
   mounted volumes (copy-based, never symlinks), so the default theme and
   bundled plugins appear on a brand-new shadowing volume.
4. **Leave `uploads` unseeded** (user media only).
5. **Ownership** — repair root-owned mount roots; only recursive-chown when the
   mount root is not already owned by `www-data`.

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

## Environment

| Variable | Purpose |
|---|---|
| `WORDPRESS_DB_HOST` | DB host |
| `WORDPRESS_DB_PORT` | DB port (joined into `DB_HOST`) |
| `WORDPRESS_DB_NAME` | Database name |
| `WORDPRESS_DB_USER` | DB user |
| `WORDPRESS_DB_PASSWORD` | DB password (secret) |
| `WORDPRESS_TABLE_PREFIX` | Table prefix (default `wp_`) |
| `PORTAL_WORKSPACE_URL` | Public HTTPS URL → `WP_HOME`/`WP_SITEURL` |
| `WORKSPACE_AUTH_USERNAME` | HTTP Basic Auth username (secret, enforced by the base Caddy) |
| `WORKSPACE_AUTH_PASSWORD` | HTTP Basic Auth password (secret, enforced by the base Caddy) |
| `PORT` | HTTP listen port (default `8080`) |

No numeric workspace-ID env is consumed: the container identifies itself to
the portal via `COOLIFY_RESOURCE_UUID` + `PORTAL_API_KEY`.

## HTTP Basic Auth

Public HTTP Basic Auth is enforced **by the image's Caddy layer** from the
`WORKSPACE_AUTH_USERNAME` / `WORKSPACE_AUTH_PASSWORD` secret env vars injected
by the portal (portal-plugin-ipfs PR #1031) — it is no longer the Coolify
proxy's responsibility. All non-loopback requests require valid credentials
(`401` otherwise); loopback requests (real peer `127.0.0.1` / `::1`) bypass
auth so the container's Docker health check of `/healthz` passes. The bypass
never trusts spoofable `X-Forwarded-For` / `X-Real-IP`. Missing credentials
fail the container closed. See [`images/php-caddy/README.md`](../php-caddy/README.md).

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

Proves PHP-backed health, WordPress install, fresh-volume default theme,
persistence across container recreation, ephemeral core, non-overwrite of user
content, runtime-user writability, and non-root final processes.
