# syntax=docker/dockerfile:1

## --------------------------------------------------------------------------
## Pinner PHP-FPM + Caddy base image.
##
## Purpose: a reusable, non-root PHP-FPM + Caddy runtime that any Pinner
## workspace can build on. Enforces workspace HTTP Basic Auth (WORKSPACE_AUTH_*)
## on non-loopback requests, exposes a loopback-exempt PHP-backed /healthz, and
## listens on 0.0.0.0:${PORT:-8080}.
##
## All pinned upstream inputs (current stable series, exact digests/checksums)
## live in ./versions.env — the single source of truth. docker-bake.hcl injects
## them here as build ARGs (see Makefile "Pinned upstream inputs"). This
## Dockerfile therefore declares those ARGs WITHOUT literals, so a bump only
## edits versions.env and nothing can drift between versions.env and the build.
## --------------------------------------------------------------------------

# Current stable PHP series at implementation time, pinned by exact digest.
# Values injected by bake from versions.env (PHP_BASE = image name,
# PHP_BASE_DIGEST = its sha256); the real pins live ONLY in versions.env so the
# source of truth stays in one place and cannot drift. FROM combines them into
# the same digest-pinned reference the image previously hardcoded, preserving
# reproducibility.
#
# These ARGs carry a NON-PRODUCTION placeholder default rather than an empty
# one, for two reasons: (1) it satisfies BuildKit's static FROM validation and
# removes the "InvalidDefaultArgInFrom" warning, and (2) it stays fail-closed —
# the placeholder is a well-formed but deliberately *unresolvable* image
# reference, so if bake ever fails to inject the real pins the FROM cannot
# resolve at pull time and the build fails loudly instead of silently building
# against the wrong (or no) base. It never duplicates the real pinned values,
# so it cannot drift. The placeholder is only ever used when the pins were NOT
# injected (i.e. a bypassed/mis-wired build path).
ARG PHP_BASE=pinner-php-caddy-base-unset
ARG PHP_BASE_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000

FROM ${PHP_BASE}@${PHP_BASE_DIGEST}

# -- build-time inputs -------------------------------------------------------
# Caddy release + per-arch sha512 (from upstream checksums.txt; the archive is
# verified before install so a tampered/incorrect download fails the build).
# Values injected by bake from versions.env (CADDY_VERSION / CADDY_SHA512_*).
ARG CADDY_VERSION
ARG TARGETARCH
ARG CADDY_SHA512_AMD64
ARG CADDY_SHA512_ARM64

# Image identity used by verification and releases.
ARG VERSION=0.1.0

# -- OS + PHP extensions ----------------------------------------------------
# Install build deps, compile the WordPress-needed extensions, then purge dev
# packages so the layer stays slim. Keep runtime libraries the extensions link
# against and the setpriv utility we use for privilege dropping.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libcap2-bin \
        libcurl4-openssl-dev \
        libfreetype6-dev \
        libicu-dev \
        libjpeg62-turbo-dev \
        libonig-dev \
        libpng-dev \
        libwebp-dev \
        libxml2-dev \
        libzip-dev \
        zlib1g-dev \
        util-linux \
    ; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    # opcache is deliberately omitted: it is already compiled into the PHP 8.5
    # base image core (php -m shows "Zend OPcache"), and docker-php-ext-install
    # opcache fails to produce a shared module here. Its php.ini settings apply
    # via conf.d/zz-pinner.ini.
    docker-php-ext-install -j"$(nproc)" \
        mysqli \
        pdo_mysql \
        gd \
        zip \
        intl \
        exif \
    ; \
    apt-get purge -y --auto-remove \
        git \
        libcurl4-openssl-dev \
        libfreetype6-dev \
        libicu-dev \
        libjpeg62-turbo-dev \
        libonig-dev \
        libpng-dev \
        libwebp-dev \
        libxml2-dev \
        libzip-dev \
        zlib1g-dev \
    ; \
    # Reinstall the runtime shared libraries the compiled extensions link
    # against: --auto-remove above removed them too (they were only pulled in
    # as dependencies of the -dev packages), which would make the gd/zip/intl
    # dynamic modules fail to load at runtime. Explicitly reinstalling marks
    # them as manually installed so a later autoremove cannot drop them.
    apt-get install -y --no-install-recommends \
        libpng16-16 \
        libjpeg62-turbo \
        libwebp7 \
        libfreetype6 \
        libzip4 \
        libicu72 \
        libonig5 \
        libxml2 \
        libcurl4 \
        zlib1g \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# -- Caddy ------------------------------------------------------------------
# Download the pinned Caddy .deb, verify its sha512, then install. The .deb is
# a self-contained static Go binary with no runtime dependencies.
# CADDY_VERSION / TARGETARCH / CADDY_SHA512_* are build ARGs, available to the
# shell as env vars; reference them with a single $ (Docker substitutes declared
# ARGs at build time). `url`/`caddy_sha512` are plain shell vars.
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) caddy_sha512="$CADDY_SHA512_AMD64" ;; \
      arm64) caddy_sha512="$CADDY_SHA512_ARM64" ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${TARGETARCH}.deb"; \
    curl -fsSL -o /tmp/caddy.deb "$url"; \
    echo "$caddy_sha512  /tmp/caddy.deb" | sha512sum -c -; \
    dpkg -i /tmp/caddy.deb; \
    rm -f /tmp/caddy.deb

# -- runtime config ---------------------------------------------------------
# PHP-FPM: listen loopback, workers as www-data. When the master is started as
# www-data (after our privilege drop) the pool user/group directives are simply
# ignored, which is exactly what we want.
COPY php-fpm.conf /usr/local/etc/php-fpm.d/zz-pinner.conf

# PHP runtime settings tuned for a WordPress workspace (uploads, opcache).
COPY php.ini /usr/local/etc/php/conf.d/zz-pinner.ini

# Caddy serves /var/www/html, routes /healthz through PHP, forwards to the
# loopback PHP-FPM socket, and enforces workspace HTTP Basic Auth on
# non-loopback requests (WORKSPACE_AUTH_* injected by the portal).
COPY Caddyfile /etc/caddy/Caddyfile

# Local loopback-exempt health probe; proves PHP-FPM is processing requests.
COPY healthz.php /var/www/html/healthz.php

# Runtime scaffolding: entrypoint (privileged init + auth + privilege drop),
# the auth setup sourced by the entrypoint, and the supervisor that keeps both
# Caddy and PHP-FPM alive as non-root processes.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY pinner-auth-setup.sh /usr/local/bin/pinner-auth-setup.sh
COPY pinner-supervise.sh /usr/local/bin/pinner-supervise.sh

# Make the runtime scripts executable (COPY preserves source perms, so set
# explicitly rather than relying on the host umask/umask lineage).
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/pinner-auth-setup.sh /usr/local/bin/pinner-supervise.sh

# Optional privileged init hook; child images (e.g. WordPress) point this at a
# script that seeds/chowns mounted volumes before the privilege drop.
ENV PINNER_INIT=""

# Caddy (run as www-data with HOME=/var/www) needs writable home-relative
# storage for its config autosave and TLS storage; a non-root user cannot create
# these dirs, so pre-provision and own them here.
# /var/www/log is where the non-root PHP-FPM master writes its error log (it
# cannot reopen the container's root-owned stdout pipe). Created here and owned
# by www-data so FPM can create the log file at startup; pinner-supervise.sh
# relays this file into the container log stream so PHP logs reach
# docker/Coolify logs.
RUN mkdir -p /var/www/.config/caddy /var/www/.local/share/caddy /var/www/log \
 && chown -R www-data:www-data /var/www

WORKDIR /var/www/html
ENV PORT=8080
EXPOSE 8080

# Container healthcheck, on the same PHP-backed /healthz route that compose
# and the verification scripts use. Shell form so ${PORT} resolves from the
# container environment at runtime (dynamic listen port), and `curl -f` fails
# on any non-2xx so the health state truthfully reflects a 200 from PHP-FPM.
# This runs against localhost inside the container, which the remote_ip
# loopback exemption treats as authenticated — no credentials are needed here.
# Runs as root (no USER set); curl is installed above.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS "http://localhost:${PORT:-8080}/healthz" || exit 1

# The official php: base image sets STOPSIGNAL SIGQUIT (for php-fpm's graceful
# reload), but our supervisor that co-runs caddy + php-fpm only handles
# TERM/INT. Override to SIGTERM so `docker stop` triggers our clean shutdown
# handler instead of being ignored by PID1 and escalated to SIGKILL.
STOPSIGNAL SIGTERM

# The entrypoint runs as root to prepare volumes, then `exec`s setpriv to drop
# to www-data before the supervisor starts any app process.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

LABEL org.opencontainers.image.title="pinner-php-caddy" \
      org.opencontainers.image.description="Pinner PHP-FPM + Caddy base runtime" \
      org.opencontainers.image.version="${VERSION}"
