# syntax=docker/dockerfile:1

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

# -- startup init hook --------------------------------------------------------
# Runs as root before the base drops privileges: copies core into the ephemeral
# docroot, seeds persistent themes/plugins onto (possibly root-owned) volumes,
# generates wp-config.php, fixes ownership, and only then lets the base drop to
# www-data and start Caddy + PHP-FPM.
COPY wp-init.sh /usr/local/bin/pinner-wp-init
COPY wp-config-generator.php /usr/local/bin/wp-config-generator

RUN chmod +x /usr/local/bin/pinner-wp-init /usr/local/bin/wp-config-generator
ENV PINNER_INIT=/usr/local/bin/pinner-wp-init

LABEL org.opencontainers.image.title="workspace-wordpress" \
      org.opencontainers.image.description="Pinner WordPress on Caddy + PHP-FPM" \
      org.opencontainers.image.version="${VERSION}"
