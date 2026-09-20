# syntax=docker/dockerfile:1

## --------------------------------------------------------------------------
## workspace-init builder stage
##
## Compiles the tiny workspace-init Go CLI (fetches the workspace owner's email
## from the portal via PORTAL_API_URL/PORTAL_API_KEY) into a statically linked
## binary. GO_BASE / GO_BASE_DIGEST are injected by docker-bake.hcl from
## images/wordpress/versions.env — the single source of truth. The non-production
## placeholder defaults fail the build loudly if bake ever forgets to inject
## the real pins, matching the php-caddy base's fail-closed FROM strategy.
## --------------------------------------------------------------------------
ARG GO_BASE=workspace-init-builder-unset
ARG GO_BASE_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
FROM ${GO_BASE}@${GO_BASE_DIGEST} AS workspace-init-builder
WORKDIR /src
# Copy manifests first so `go mod download` is cached independently of source
# edits, then build with CGO disabled for a self-contained static binary that
# runs on the slim PHP/WordPress runtime that has no libc dev toolchain.
COPY workspace-init/go.mod workspace-init/go.sum ./
RUN go mod download
COPY workspace-init/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/workspace-init .

## --------------------------------------------------------------------------
## Pinner WordPress image: WordPress served by Caddy on PHP-FPM.
##
## Built on the php-caddy base. The `base` named context is provided by
## docker-bake.hcl (`contexts.base = target:php-caddy`), so the base is built
## first and consumed here.
##
## Layout follows official WordPress conventions:
##   immutable source: /usr/src/wordpress
##   runtime docroot : /var/www/html  (ephemeral; only wp-content subdirs mount)
## --------------------------------------------------------------------------

# Provided by docker-bake.hcl as the built php-caddy target
# (contexts.base = "target:php-caddy"). `base` must be referenced by name, not
# via ${} substitution (which buildkit would treat as an ARG, leaving it blank).
FROM base

# -- build-time inputs -------------------------------------------------------
# Current stable WordPress release, pinned to its exact archive sha256. The
# values live only in ./versions.env and are injected here by docker-bake.hcl
# (no literals, so they cannot drift). Verify with `make deps-verify`.
ARG WORDPRESS_VERSION
ARG WORDPRESS_SHA256

# WP-CLI release + sha512 (from its official release checksum), injected from
# versions.env the same way; downloaded and verified then baked into the image.
ARG WP_CLI_VERSION
ARG WP_CLI_SHA512
ARG VERSION=0.1.0

# -- WordPress core (immutable) ---------------------------------------------
# Download, verify, and extract WordPress to /usr/src/wordpress. This stays in
# the image layer as the immutable seed/copy source; the runtime docroot is
# populated on first boot from here so core stays ephemeral per container.
RUN set -eux; \
    curl -fsSL -o /tmp/wordpress.tar.gz \
        "https://downloads.wordpress.org/release/wordpress-${WORDPRESS_VERSION}.tar.gz"; \
    echo "${WORDPRESS_SHA256}  /tmp/wordpress.tar.gz" | sha256sum -c -; \
    mkdir -p /usr/src/wordpress; \
    tar -xzf /tmp/wordpress.tar.gz -C /usr/src/wordpress --strip-components=1; \
    rm -f /tmp/wordpress.tar.gz

# -- WP-CLI (baked in) --------------------------------------------------------
# Install wp-cli pinned to its exact release sha512, verified before install so
# a tampered/incorrect download fails the build. Used by wp-init.sh for
# `wp config create`, `wp core install` and the per-boot admin password
# converge, so no separate wp-cli download is needed at runtime/verify time.
# WP-CLI ships as a self-contained phar. We install it as wp-cli.phar and expose
# a `wp` wrapper that runs it through `php -d error_reporting=22527`, so the
# deprecation notices WP-CLI's bundled react/promise emits under PHP 8.5 (e.g.
# "Case statements followed by a semicolon are deprecated") do NOT leak onto
# stdout and corrupt parsed output such as `wp option get siteurl`.
# error_reporting=22527 == E_ALL & ~E_DEPRECATED for this PHP (E_ALL=30719).
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/wp-cli.phar \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"; \
    echo "${WP_CLI_SHA512}  /usr/local/bin/wp-cli.phar" | sha512sum -c -; \
    chmod +x /usr/local/bin/wp-cli.phar; \
    printf '%s\n' '#!/bin/sh' 'set -eu' \
        'exec php -d error_reporting=22527 /usr/local/bin/wp-cli.phar "$@"' \
        > /usr/local/bin/wp && chmod +x /usr/local/bin/wp

# The workspace-init CLI (owner-email helper) from the builder stage above.
COPY --from=workspace-init-builder /out/workspace-init /usr/local/bin/workspace-init

# -- startup init hook --------------------------------------------------------
# Runs as root before the base drops privileges: copies core into the ephemeral
# docroot, seeds persistent themes/plugins onto (possibly root-owned) volumes,
# generates wp-config.php (via WP-CLI), runs automatic first-boot install +
# per-boot admin password converge, fixes ownership, and only then lets the
# base drop to www-data and start Caddy + PHP-FPM.
COPY wp-init.sh /usr/local/bin/pinner-wp-init

# -- WP-CLI cron worker --------------------------------------------------------
# Supervised background cron driver (see pinner-wp-cron.sh). Passed to the base
# supervisor via PINNER_SUPERVISED_CMD and run as www-data after the privilege
# drop; replaces WP's web-triggered cron (which wp-config.php disables).
COPY pinner-wp-cron.sh /usr/local/bin/pinner-wp-cron

RUN chmod +x /usr/local/bin/pinner-wp-init /usr/local/bin/pinner-wp-cron /usr/local/bin/workspace-init
ENV PINNER_INIT=/usr/local/bin/pinner-wp-init
ENV PINNER_SUPERVISED_CMD=/usr/local/bin/pinner-wp-cron

LABEL org.opencontainers.image.title="workspace-wordpress" \
      org.opencontainers.image.description="Pinner WordPress on Caddy + PHP-FPM" \
      org.opencontainers.image.version="${VERSION}"
