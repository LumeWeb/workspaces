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
| `workspace-wordpress` | WordPress workspace | WordPress `7.1` on the base |

All upstream bases are **pinned**: exact PHP digest, exact Caddy release with
per-arch sha512, and the exact WordPress archive sha256. Releases additionally
publish a floating `:latest` tag (see [Versioning / releases](#versioning--releases)),
always alongside an immutable per-version tag when a version is known.

## Pinning / single source of truth

Every upstream version, digest, and checksum lives in exactly **one** place —
the `versions.env` files:

- `images/php-caddy/versions.env` → PHP base + Caddy version and per-arch sha512
- `images/wordpress/versions.env` → WordPress version + archive sha256, and the
  WP-CLI version + sha512 and Go builder image (name + digest) baked into the
  image

The `Makefile` `include`s those files, `export`s the variables, and
`docker-bake.hcl` reads them back from the process environment. Bake injects the
values into the **Docker build ARGs** and mirrors them into **runtime OCI
labels**. The Dockerfiles declare those ARGs **with no hardcoded *production*
default literal**, so a real pin value exists in exactly one place and can never
drift from what is actually built. The two FROM ARGs in the php-caddy
Dockerfile carry a well-formed but deliberately **unresolvable non-production
placeholder** default: it satisfies BuildKit's static FROM validation (no
"InvalidDefaultArgInFrom" warning) while still failing the build fast if bake
ever fails to inject the real pins — without duplicating a real version/digest:

```text
versions.env ──► Makefile (include + export) ──► docker-bake.hcl variables
                                                        │
                                                        ├─► Docker build ARGs (PHP_BASE, CADDY_VERSION, …)
                                                        └─► OCI runtime labels (base.digest, caddy.version, …)
```

To bump an upstream: edit the relevant `versions.env`, then run
`make deps-verify` (re-checks upstream plus asserts bake forwards the same
values) and the build/verify matrix. If bake wiring ever stops forwarding a pin,
`make deps-verify` fails loudly rather than building an image that does not match
`versions.env`.

### Docker ARG vs ENV (why versions are ARGs)

- **`ARG`** is a **build-time** variable: it exists only while the build runs
  (available to `FROM`, `RUN`, and `LABEL` substitution inside the Dockerfile)
  and is **not** retained in the final image or exposed at runtime.
- **`ENV`** is a **runtime** variable: baked into the image and present in every
  running container's environment.

Upstream versions/digests/checksums are pure build inputs — they are consumed to
fetch and verify artifacts during `docker build` and are of no use to the
running container — so they are correctly modeled as **ARGs**. Using `ENV` for
them would needlessly bloat the runtime environment (and leak pin metadata into
`docker inspect`/`env`). Runtime configuration that the container actually needs
today — `PORT`, `WORKSPACE_AUTH_*`, `PINNER_INIT`, DB settings — is delivered as
`ENV` at runtime. The one build value that is also useful as **metadata** (the
PHP/Caddy/WordPress pins) is exposed after the build via OCI **labels**, which
come from the same single source without duplicating literals or polluting the
runtime environment.

## Repository layout

```
.
├── Makefile                     # build / lint / verify targets
├── docker-bake.hcl              # image assembly; injects pins from versions.env
├── compose/                     # local verification stacks (Compose)
├── images/
│   ├── php-caddy/               # PHP-FPM + Caddy base image (+ versions.env pins)
│   └── wordpress/               # WordPress workspace image (+ versions.env pins)
└── scripts/                     # verification + pin checks
```

## Building

```sh
make build          # build all images for the current platform
make lint           # shellcheck (+ hadolint if installed)
```

Images are produced by `docker buildx bake`. Bake reads the upstream pins from
the process environment, so they must be loaded from `versions.env` first —
`make` does this for you, so prefer the `make` targets:

```sh
# Preferred: pins are exported + fed to bake automatically, and the built images
# are tagged + loaded into the local docker daemon for verification.
make build-php-caddy

# Equivalent manual path (source the pins, then load the local tags).
set -a; . images/php-caddy/versions.env; . images/wordpress/versions.env; set +a
docker buildx bake --load \
                   --set php-caddy.tags=pinner-php-caddy:local \
                   --set wordpress.tags=workspace-wordpress:local \
                   php-caddy wordpress
```

**Local vs release references.** `make build`/`build-*` tag the images with
**local-only** names (e.g. `pinner-php-caddy:local`) and `--load` them into the
local docker daemon. That is required under the **`docker-container` buildx
driver**, which otherwise leaves the build result in the cache (a "No output
specified" / "image remains cache" warning) and never puts it where Compose can
reach it. The GHCR release references (`ghcr.io/lumeweb/pinner-php-caddy:<version>`,
derived from `REGISTRY`/`VERSION`) are used **only** by the CD release workflow
(`.github/workflows/release.yml` `--push`); local build/verify never touch them,
so a local run needs no registry access or authentication.

Because the Dockerfiles carry **no** hardcoded *production* pin literals,
invoking `bake` without the pins sourced fails the build loudly (unresolvable
placeholder `FROM`/empty checksum) rather than silently drifting.

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
  / `WORKSPACE_AUTH_PASSWORD` secret env vars on all requests whose **resolved
  client IP** is external/public (portal-plugin-ipfs PR #1031) — including
  every proxied request where the Coolify proxy forwards a public-range
  `X-Forwarded-For` — not by the Coolify proxy. Bypass keys on the
  private-range resolved client IP via Caddy's `client_ip` through
  `trusted_proxies`: in-deployment probes (e.g. Cast's anonymous export probe
  hairpinning through the published port) and the health check stay
  unauthenticated; a public-range peer's spoofed forwarding headers are
  ignored (untrusted); missing credentials fail the container closed.
- DB via `WORDPRESS_DB_HOST/PORT/NAME/USER/PASSWORD`; public URL via
  `COOLIFY_URL` (sets `WP_HOME`/`WP_SITEURL` and drives `wp core install`);
  `X-Forwarded-*` drives HTTPS-correct links.
- **Automatic bootstrap** (image-side): WP-CLI + the `workspace-init` Go CLI are
  baked in. On first boot `workspace-init` exchanges `PORTAL_API_KEY` for a
  login-purpose JWT via the portal, reads the owner's email from `GetAccount`,
  and `wp-init.sh` runs `wp core install --url=$COOLIFY_URL` with the owner
  email and the existing `WORKSPACE_AUTH_*` credentials. Every boot converges
  the WordPress admin password to the current `WORKSPACE_AUTH_PASSWORD`. No
  portal or dashboard code changes.

## How persistence + root-owned volumes work

Docker/Coolify named volumes may be mounted **`root:root`**, and a fresh mount
**shadows** the image's bundled content at `/var/www/html/wp-content/*`. The
WordPress entrypoint therefore runs **as root first**:

1. Seeds WordPress core into the ephemeral docroot from `/usr/src/wordpress`.
2. One-time **copy-based** seed of `themes` and `plugins` from the immutable
   source onto their mounted volumes (uploads is never seeded).
3. Generates an ephemeral `wp-config.php` with WP-CLI `wp config create`
   (DB/secret values on stdin), then runs the automatic first-boot
   `wp core install` (owner email from the portal via the baked-in
   `workspace-init` CLI) and converges the admin password on every boot.
4. Repairs ownership — recursive `chown` only when the mount root is not
   already owned by `www-data` (avoids reapplying recursive chown on large
   `uploads` volumes every boot).
5. Permanently **drops to `www-data`** via `setpriv`, then starts Caddy +
   PHP-FPM as non-root.

Seeding is `flock`-serialized and idempotent: interrupted or concurrent first
boots finish cleanly, and existing user data on an unmarked volume is never
overwritten. See `images/wordpress/README.md` for the security trade-off.

## Verification

```sh
make verify           # build everything, then run the full matrix
make verify-wordpress # build + verify WordPress with MariaDB
make verify-php-caddy # verify the base image
make deps-verify      # re-check upstream pins AND that bake forwards them (no drift)
```

Every `verify-*` target builds + loads the local images first, then exercises
those **local-only tags** through Compose. The scripts refuse to verify a
published/remote (registry-qualified) reference and require the built image to
be present in the local daemon; if you pass `--image ghcr.io/...` or a name that
isn't loaded locally, they fail with a clear error instead of pulling — a local
`make verify` therefore never needs GHCR authentication.

`make verify-wordpress` boots WordPress + MariaDB via Compose and proves:

- PHP-backed `/healthz` returns `200`
- the image automatically installs WordPress on first boot (owner email from
  the mock portal, `COOLIFY_URL` as the site URL), and the default theme
  activates
- per-boot admin password rotation converges to a changed
  `WORKSPACE_AUTH_PASSWORD`
- default theme + bundled plugins appear on a **fresh shadowing volume**
- uploads starts empty; plugins/themes/uploads **survive container
  recreation**; user content is **not overwritten**
- core-only marker is **ephemeral**, `wp-config.php` regenerates
- deleted bundled plugin is **not resurrected**
- mounted dirs are **writable by the runtime user**
- final Caddy/PHP-FPM processes are **non-root**

## Versioning / releases

Images are published with an **immutable, per-release recipe tag** derived from
the git tag, plus a floating `:latest`:

- A pushed tag `vX.Y.Z` publishes `:<X.Y.Z>` **and** `:latest`.
- A manual (`workflow_dispatch`) run publishes `:<version>` **and** `:latest`
  when a `version` input is provided.
- A manual run with the `version` input left **blank** publishes `:latest`
  only (no empty/invalid version tag is produced).

```text
ghcr.io/lumeweb/workspace-wordpress:0.1.0 + :latest   # from git tag v0.1.0
ghcr.io/lumeweb/pinner-php-caddy:0.1.0   + :latest    # from git tag v0.1.0
ghcr.io/lumeweb/workspace-wordpress:latest            # manual, no version
```

`VERSION` (the recipe) in `docker-bake.hcl`/`Makefile`/`release.yml` is the
`X.Y.Z` component; it drives both the image tags and the build-arg/label sourced
from it (an empty `VERSION` omits the per-version tag and keeps only `:latest`).
Releases build `linux/amd64` + `linux/arm64` and report digests against the
resolved published tag (see `.github/workflows/release.yml`).

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
