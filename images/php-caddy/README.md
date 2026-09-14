# php-caddy

Reusable base image: **PHP-FPM + Caddy**, the runtime every Pinner workspace
image builds on. Non-root after startup, no integrated app logic. Enforces
workspace HTTP Basic Auth on public (non-loopback) requests.

| Aspect | Value |
|---|---|
| Base | `php:8.5.10-fpm-bookworm` (digest-pinned) |
| Caddy | `2.11.4` (sha512-verified `.deb`) |
| EXTensions | `mysqli pdo_mysql gd zip intl exif opcache` |
| Listen | `0.0.0.0:${PORT:-8080}` |
| Document root | `/var/www/html` |
| PHP-FPM | `127.0.0.1:9000` |
| Runtime user | `www-data` |

## HTTP Basic Auth (portal-plugin-ipfs PR #1031)

The Pinner portal injects two **secret** environment variables, and this image
enforces them with Caddy's `basicauth` on every **non-loopback** request:

- `WORKSPACE_AUTH_USERNAME`
- `WORKSPACE_AUTH_PASSWORD`

Behavior:

- **Non-loopback** requests (the actual TCP peer is not `127.0.0.1`/`::1`) must
  present valid HTTP Basic Auth credentials, otherwise they get `401`.
- **Loopback** requests (real peer `127.0.0.1` or `::1`) bypass auth, so the
  container's own Docker/Coolify health probe of `/healthz` passes without
  credentials. The portal itself never HTTP-probes the workspace URL.
- The bypass keys on Caddy's `remote_ip` matcher — the **real peer IP**, never
  spoofable `X-Forwarded-For` / `X-Real-IP` headers.
- **Fail closed**: if either `WORKSPACE_AUTH_*` var is missing/empty at start,
  the container refuses to start rather than serve the workspace publicly
  unauthenticated. This matches the portal's environment builder, which fails
  closed when the workspace row lacks credentials, so a provisioned workspace
  always provides both. There is deliberately **no** auth-disabled mode.
- **Rotation**: the portal applies rotated credentials as a secret-env upsert
  of the two `WORKSPACE_AUTH_*` vars followed by a redeploy. On each container
  start the entrypoint re-derives a fresh Caddy hash from the current
  environment, so the new credential takes effect on redeploy/restart.

Secret hygiene: the plaintext password is fed to `caddy hash-password` on
**stdin** (never argv, so it doesn't appear in `/proc`), and only the derived
bcrypt hash is carried transiently in the process environment. Credentials and
hashes are never written to disk or echoed to logs.

## Health

`GET /healthz` returns `200` and is routed **through PHP-FPM** (`healthz.php`),
so it proves PHP handling, not just a static Caddy file. It is the Docker
healthcheck path. Because it is reached from localhost, the loopback exemption
makes it auth-free; a non-loopback `/healthz` is gated like any other route.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | HTTP listen port |
| `WORKSPACE_AUTH_USERNAME` | *(required)* | HTTP Basic Auth username (secret) |
| `WORKSPACE_AUTH_PASSWORD` | *(required)* | HTTP Basic Auth password (secret) |
| `PINNER_INIT` | *(unset)* | Optional root init hook path for child images |

## Privilege model

1. Container starts as **root** so the entrypoint (or a child image's
   `PINNER_INIT` hook) can chown/seed mounted volumes.
2. The entrypoint validates/derives `WORKSPACE_AUTH_*` (fail-closed), then
   `exec`s `setpriv` to drop to **www-data** permanently.
3. `pinner-supervise.sh` runs both Caddy and PHP-FPM as www-data, forwarding
   shutdown signals so neither is orphaned.

## Building

```sh
make build-php-caddy
```

## Hooks for child images

Set `ENV PINNER_INIT=/path/to/script` from a child Dockerfile. The hook runs as
root before the auth validation and privilege drop; use it to seed persistent
volumes and fix root-owned mounts. See `images/wordpress` for a concrete
example.
