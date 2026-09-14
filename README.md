# Pinner Workspace Images

Monorepo of Docker images that run **Pinner portal workspaces**. Each workspace
is a self-contained runtime (web server + application runtime) deployed as a
Coolify resource backed by external MariaDB/MySQL.

The first image is **WordPress served by Caddy on PHP-FPM**, built on a reusable
`php-caddy` base.

## Images

| Image | Description | Runtime |
|---|---|---|
| `pinner-php-caddy` | Reusable PHP-FPM + Caddy base | `php:8.5.10` + Caddy `2.11.4` |
| `pinner-wordpress` | WordPress workspace | WordPress `7.1` on the base |

All upstream bases are **pinned**: exact PHP digest, exact Caddy release with
per-arch sha512, and the exact WordPress archive sha256. No floating
production `latest` tag.

## Repository layout

```
.
├── Makefile                     # build / lint / verify targets
├── docker-bake.hcl              # single source of truth for image assembly
├── compose/                     # local verification stacks (Compose)
├── images/
│   ├── php-caddy/               # PHP-FPM + Caddy base image
│   └── wordpress/               # WordPress workspace image
└── scripts/                     # verification + pin checks
```

## Building

```sh
make build          # build all images for the current platform
make lint           # shellcheck (+ hadolint if installed)
```

Images are produced by `docker buildx bake`:

```sh
docker buildx bake --set php-caddy.tags=pinner-php-caddy:local \
                   --set wordpress.tags=pinner-wordpress:local \
                   php-caddy wordpress
```

Because `wordpress` layers on `php-caddy`, bake builds the base first and feeds
it as a named context (`contexts.base = target:php-caddy`).

## Conventions

- **Document root**: `/var/www/html`
- **Immutable source**: `/usr/src/wordpress`
- **Listen**: `0.0.0.0:${PORT:-8080}`
- **Non-root runtime**: final processes run as `www-data`
- **Persistence** (exactly three paths):
  - `/var/www/html/wp-content/themes`
  - `/var/www/html/wp-content/plugins`
  - `/var/www/html/wp-content/uploads`
- Everything else under `/var/www/html` (core, `wp-config.php`, caches) is
  **ephemeral** per container.
- **`/healthz`**: dedicated PHP-backed health probe, **loopback-exempt** (the
  container's Docker health check reaches it from `localhost` without auth).
- **HTTP Basic Auth**: enforced by the image from the `WORKSPACE_AUTH_USERNAME`
  / `WORKSPACE_AUTH_PASSWORD` secret env vars on all **non-loopback** requests
  (portal-plugin-ipfs PR #1031) — not by the Coolify proxy. Loopback bypass keys
  on the real peer IP (`remote_ip`), never spoofable forwarding headers; missing
  credentials fail the container closed.
- DB via `WORDPRESS_DB_HOST/PORT/NAME/USER/PASSWORD`; public URL via
  `PORTAL_WORKSPACE_URL`; `X-Forwarded-*` drives HTTPS-correct links.

## How persistence + root-owned volumes work

Docker/Coolify named volumes may be mounted **`root:root`**, and a fresh mount
**shadows** the image's bundled content at `/var/www/html/wp-content/*`. The
WordPress entrypoint therefore runs **as root first**:

1. Seeds WordPress core into the ephemeral docroot from `/usr/src/wordpress`.
2. One-time **copy-based** seed of `themes` and `plugins` from the immutable
   source onto their mounted volumes (uploads is never seeded).
3. Repairs ownership — recursive `chown` only when the mount root is not
   already owned by `www-data` (avoids reapplying recursive chown on large
   `uploads` volumes every boot).
4. Permanently **drops to `www-data`** via `setpriv`, then starts Caddy +
   PHP-FPM as non-root.

Seeding is `flock`-serialized and idempotent: interrupted or concurrent first
boots finish cleanly, and existing user data on an unmarked volume is never
overwritten. See `images/wordpress/README.md` for the security trade-off.

## Verification

```sh
make verify           # build everything, then run the full matrix
make verify-wordpress # build + verify WordPress with MariaDB
make verify-php-caddy # verify the base image
make deps-verify      # re-check pinned upstream checksums
```

`make verify-wordpress` boots WordPress + MariaDB via Compose and proves:

- PHP-backed `/healthz` returns `200`
- WordPress installs (wp-cli), default theme activates
- default theme + bundled plugins appear on a **fresh shadowing volume**
- uploads starts empty; plugins/themes/uploads **survive container
  recreation**; user content is **not overwritten**
- core-only marker is **ephemeral**, `wp-config.php` regenerates
- deleted bundled plugin is **not resurrected**
- mounted dirs are **writable by the runtime user**
- final Caddy/PHP-FPM processes are **non-root**

## Versioning / releases

Images are published with an **immutable, per-release recipe tag** derived from
the git tag: a pushed tag `vX.Y.Z` publishes `:<X.Y.Z>` (never a floating
`latest`).

```text
ghcr.io/lumeweb/pinner-wordpress:0.1.0    # from git tag v0.1.0
ghcr.io/lumeweb/pinner-php-caddy:0.1.0    # from git tag v0.1.0
```

`VERSION` (the recipe) in `docker-bake.hcl`/`Makefile`/`release.yml` is the
`X.Y.Z` component; it drives both the image tags and the build-arg/label sourced
from it. Releases build `linux/amd64` + `linux/arm64`, publish immutable recipe
tags, and report digests (see `.github/workflows/release.yml`). A mutable
`stable` moving tag may be maintained **in addition** to, never instead of,
immutable tags.

## Portal configuration

The portal injects the three persistent mounts as a zero-based, **contiguous**
env-var array (`STORAGE_0`, `STORAGE_1`, `STORAGE_2` — never a repeated index,
which would collapse and drop the whole array):

```text
PORTAL__SERVICE__IPFS__WORKSPACE__RUNTIME__STORAGE_0='{"name_suffix":"themes","mount_path":"/var/www/html/wp-content/themes"}'
PORTAL__SERVICE__IPFS__WORKSPACE__RUNTIME__STORAGE_1='{"name_suffix":"plugins","mount_path":"/var/www/html/wp-content/plugins"}'
PORTAL__SERVICE__IPFS__WORKSPACE__RUNTIME__STORAGE_2='{"name_suffix":"uploads","mount_path":"/var/www/html/wp-content/uploads"}'
```

The portal passes each `mount_path` through unchanged; the image owns these
paths. Runtime image/tag/port/health-path settings and the storage contract are
documented in [`images/wordpress/README.md`](images/wordpress/README.md).

## License

See [LICENSE](LICENSE).
