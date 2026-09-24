# php-caddy

Reusable base image: **PHP-FPM + Caddy**, the runtime every Pinner workspace
image builds on. Non-root after startup, no integrated app logic. Enforces
workspace HTTP Basic Auth on requests whose resolved client IP is public
(proxied public clients included).

| Aspect | Value |
|---|---|
| Base | `php:8.5.10-fpm-bookworm` (digest-pinned) |
| Caddy | `2.11.4` (sha512-verified `.deb`) |
| EXTensions | `mysqli pdo_mysql gd zip intl exif opcache` |
| Listen | `0.0.0.0:${PORT:-8080}` |
| Document root | `/var/www/html` |
| PHP-FPM | `127.0.0.1:9000` |
| Runtime user | `www-data` |

## Version pins — single source of truth

The PHP base and Caddy version/digests live **only** in `images/php-caddy/versions.env`.
The build (`docker-bake.hcl`) injects them as Docker ARGs and mirrors them into
the OCI labels; the `Dockerfile` declares those ARGs **without hardcoded
literals**, so there is no second copy to drift. Bump by editing
`versions.env`, then run `make deps-verify` (which also asserts bake forwards
the same values) and rebuild. Verify with `make deps-verify`.

## HTTP Basic Auth (portal-plugin-ipfs PR #1031)

The Pinner portal injects two **secret** environment variables, and this image
enforces them with Caddy's `basicauth` on every request whose **resolved client
IP** is external (public-range):

- `WORKSPACE_AUTH_USERNAME`
- `WORKSPACE_AUTH_PASSWORD`

Behavior:

- **External** requests (resolved client IP is a public address) must present
  valid HTTP Basic Auth credentials, otherwise they get `401`. This includes
  every request forwarded by the Coolify proxy for a public client: the proxy
  is a private-range trusted peer whose `X-Forwarded-For` carries the real
  public client IP. Keying the bypass on the raw TCP peer instead would exempt
  the proxy's own private-range peer address and silently disable auth for the
  whole internet.
- **Loopback** requests (client IP `127.0.0.1` or `::1`) and **private-network**
  requests (RFC 1918 / ULA ranges: `10.0.0.0/8`, `172.16.0.0/12`,
  `192.168.0.0/16`, `fc00::/7`) bypass auth. Loopback covers the container's
  own Docker/Coolify health probe of `/healthz` (it sends no forwarded
  headers, so its client IP is the loopback peer itself). Private-network
  coverage keeps in-deployment consumers — the Coolify proxy's plain-HTTP hop
  for private-range forwarded clients, and any service inside the deployment's
  Docker network that requests the workspace's *public* URL (e.g. Cast's
  anonymous export probe and capture fetches via
  `wp_remote_get(home_url('/'))`, arriving with a private-range XFF hop or as
  a direct hairpinned private peer) — outside "the internet" in the auth
  threat model. The portal itself never HTTP-probes the workspace URL.
- The bypass resolves the client IP with Caddy's `client_ip` matcher through
  the `trusted_proxies` setting (private ranges): a private-range peer's
  `X-Forwarded-For` determines the client IP, while a public-range peer is
  untrusted, so its (attacker-controlled) `X-Forwarded-For` / `X-Real-IP` is
  ignored and the real peer address is used. A trusted private peer cannot
  gain a bypass by forging a *public* X-Forwarded-For — that only moves the
  request into the authenticated "external" set.
- Trust assumption: the deployment's proxy always sets `X-Forwarded-For`
  (Coolify's Traefik/Caddy do by default). An XFF-less private proxy would
  resolve to its own private IP and be exempt — an accepted part of the
  private-network contract below.
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

## Trusted upstream proxy (forwarded headers)

The workspace always sits behind the upstream Coolify proxy, which terminates
TLS and connects to this Caddy in plain HTTP over a private network. Caddy's
default is to treat incoming `X-Forwarded-*` as spoofable and overwrite
`X-Forwarded-Proto` with its own observed scheme (`http`), so the application
would never learn the original request was HTTPS. The Caddyfile therefore sets
the global `servers > trusted_proxies static private_ranges` option: requests
from the private-network proxy are trusted and their forwarded headers
(`X-Forwarded-Proto` / `X-Forwarded-Host`) reach the application unmodified.
This keeps WordPress `is_ssl()` correct behind TLS termination and avoids the
`force_ssl_admin()` login redirect loop. The same trust decision is what makes
the Basic Auth bypass resolve the real client IP: a private-range peer's
forwarded headers honor `X-Forwarded-For`, while a public-range (untrusted)
peer's spoofed headers are ignored.

`private_ranges` is as narrow as a generic image can be pinned to: the upstream
proxy's source IP varies per deployment (Docker bridge / overlay network), so an
exact proxy CIDR cannot be known at build time. Trusting all private-range peers
is an accepted risk: an attacker would need to already sit on the deployment's
private network. Forged `X-Forwarded-Proto` / `X-Forwarded-Host` influence only
scheme/host derivation in the application; a forged *private-range*
`X-Forwarded-For` can at most move a request from the authenticated
"in-network peer" case into the auth-exempt private set it would already fall
into, and a forged *public-range* one strictly requires more auth — never a
bypass for an outside client.

## Health

`GET /healthz` returns `200` and is routed **through PHP-FPM** (`healthz.php`),
so it proves PHP handling, not just a static Caddy file. It is the Docker
healthcheck path. Because it is reached from localhost, the loopback exemption
makes it auth-free; an external-peer `/healthz` is gated like any other route.

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

### Optional supervised worker: `PINNER_SUPERVISED_CMD`

A child image can add **one** extra supervised long-running worker (alongside
PHP-FPM and Caddy) by exporting `PINNER_SUPERVISED_CMD` — an `sh` command line
evaluated in the worker's wrapper (point it at an absolute script path). The
worker runs as `www-data` (the supervisor starts entirely after the privilege
drop) with exactly the same lifecycle guarantees as the built-in children:

- **Fail-fast first-exit semantics** — if ANY supervised process (worker
  included) dies, the supervisor terminates every survivor and exits with the
  dead child's status, so the orchestrator restarts the whole container.
  A worker that must survive transient conditions (e.g. WordPress install
  deferral) therefore needs its own internal retry, like the WP cron worker.
- **Signal handling** — `TERM`/`INT`/`QUIT` are forwarded to the worker for a
  graceful `docker stop`.
- **Opt-in** — unset, the supervisor behaves exactly as before (two children),
  so images without a worker are unaffected.

The WordPress image uses this for its WP-CLI cron driver
(`pinner-wp-cron.sh`, see `images/wordpress/README.md`). Regression scenarios
for the worker live in `scripts/test-supervisor.sh`.
