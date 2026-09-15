# AGENTS.md

Guidance for humans and agents working in this repository.

## Repository purpose

Monorepo of Docker images for Pinner portal workspaces. Each workspace image is
a self-contained runtime (web server + application runtime) that the Pinner
portal deploys as a Coolify resource backed by external MariaDB/MySQL. The
first image is `wordpress` (WordPress served by Caddy on PHP-FPM).

## Conventions

- **Document root** is `/var/www/html` and **immutable source** is
  `/usr/src/wordpress`, matching official WordPress image conventions.
- **Persistent** paths are exactly:
  - `/var/www/html/wp-content/themes`
  - `/var/www/html/wp-content/plugins`
  - `/var/www/html/wp-content/uploads`
  Everything else under `/var/www/html` (WordPress core, `wp-config.php`,
  caches, runtime state) is **ephemeral**.
- **Port** defaults to `8080`, overridable with `PORT` (listen on `0.0.0.0`).
- `/healthz` is a dedicated PHP-backed endpoint that returns `200`, reached
  by the container's own Docker/Coolify health check from `localhost`. HTTP
  Basic Auth is enforced **by the image** (Caddy) from the `WORKSPACE_AUTH_*`
  secret env vars (portal-plugin-ipfs PR #1031) on **non-loopback** requests;
  loopback requests bypass it via Caddy's `remote_ip` (real peer, never
  spoofable forwarding headers). Missing/invalid `WORKSPACE_AUTH_*` fails the
  container closed. Do not weaken this to trust forwarding headers or to add an
  auth-disabled mode.
- Database settings come from `WORDPRESS_DB_HOST/PORT/NAME/USER/PASSWORD`.
- `COOLIFY_URL` supplies the externally reachable public URL used for
  `WP_HOME`/`WP_SITEURL` and for `wp core install`; `X-Forwarded-*` from the
  upstream proxy drives the trusted HTTPS scheme (preserved in `wp-config.php`).
  Do NOT fall back to `PORTAL_WORKSPACE_URL` — the approved bootstrap contract
  is `COOLIFY_URL`.
- `wp-config.php` is generated with baked-in WP-CLI `wp config create` (mode
  `0600`, owned by www-data); first boot runs `wp core install` and every boot
  converges the WordPress admin password to `WORKSPACE_AUTH_PASSWORD`. WP-CLI
  and the `workspace-init` CLI (owner-email helper) are baked into the image and
  pinned in `images/wordpress/versions.env`.
- Final application processes (Caddy, PHP-FPM) run **non-root** as `www-data`.
  A privileged entrypoint initializes/chowns mounted volumes, then permanently
  drops privileges via `setpriv`.
- Use **copy-based** seeding from immutable image source, never symlinks.
- Secrets are never placed on argv, logged, or echoed: WP-CLI runs as www-data
  with `--prompt` so DB/admin passwords travel on stdin.

## Storage / portal contract

The portal passes `mount_path` through unchanged; it does not dictate the
in-container path. The canonical right-hand side is always
`/var/www/html/wp-content/...`. The portal injects the mounts as a zero-based,
contiguous `STORAGE_0/1/2` env array (see `images/wordpress/README.md`).

## Building and verifying

```sh
make help      # list targets
make lint      # shellcheck (hadolint if available)
make build     # build all images for current platform
make verify    # run the full local verification matrix
make verify-workspace-init  # Go unit tests for the workspace-init CLI
make verify-wordpress  # build + verify the WordPress image locally
make deps-verify      # re-check upstream pins AND that bake forwards them (no drift)
```

Upstream pins (PHP/Caddy/WordPress versions + digests/checksums) are single-
sourced in `images/*/versions.env` and injected by `docker-bake.hcl`. The
Dockerfiles must NOT hardcode pin literals; bump by editing `versions.env`.

Agent note: use the `file_write`/`file_edit` tools for edits. Never use shell
redirection, `sed`, or `awk` to modify repository files. Shell is for
inspection, builds, and tests. Run `make lint` and, when touching PHP/Go code,
the relevant package's checks from its directory — never from the repo root.

## Privilege-drop security trade-off

The entrypoint starts as root so it can fix root-owned Docker/Coolify named
volumes and seed fresh volumes before any app process runs. After that it drops
to non-root and never returns. See `images/wordpress/README.md` for the
trade-off discussion.
