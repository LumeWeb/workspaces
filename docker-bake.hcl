# The pinned upstream versions/digests live in images/*/versions.env — the single
# authoritative source. Make sources those files into the process environment
# before invoking bake, and the bake variables below read them straight from the
# environment. Those same values are then injected into the Docker build ARGs and
# the runtime OCI labels, and the Dockerfiles declare their ARGs WITHOUT hardcoded
# defaults. Net effect: a version/digest/checksum exists in exactly one place
# (versions.env) and can never drift from what is actually baked. See Makefile
# "Pinned upstream inputs" and README "Pinning / single source of truth".
variable "REGISTRY" { default = "ghcr.io/lumeweb" }
variable "VERSION"  { default = "0.1.0" }

# php-caddy upstream pins (sourced into env by Makefile from
# images/php-caddy/versions.env). Empty default + always injected by the build
# path = a missing value fails the build loudly instead of silently drifting.
variable "PHP_BASE"           { default = "" }
variable "PHP_BASE_DIGEST"    { default = "" }
variable "CADDY_VERSION"      { default = "" }
variable "CADDY_SHA512_AMD64" { default = "" }
variable "CADDY_SHA512_ARM64" { default = "" }

# wordpress upstream pins (sourced from images/wordpress/versions.env).
variable "WORDPRESS_VERSION" { default = "" }
variable "WORDPRESS_SHA256"  { default = "" }

target "_common" {
  args = {
    REGISTRY = REGISTRY
    VERSION  = VERSION
  }
  labels = {
    "org.opencontainers.image.source"  = "https://github.com/LumeWeb/workspaces"
    "org.opencontainers.image.version" = "${VERSION}"
  }
}

# php-caddy: reusable PHP-FPM + Caddy base. Must build first so wordpress can
# consume it as a named context ("target:php-caddy").
# Each target's build context is its own image directory so the Dockerfile COPY
# paths (which are relative to the context) resolve.
target "php-caddy" {
  inherits   = ["_common"]
  context    = "images/php-caddy"
  dockerfile = "Dockerfile"
  args = {
    REGISTRY           = REGISTRY
    VERSION            = VERSION
    PHP_BASE           = PHP_BASE
    PHP_BASE_DIGEST    = PHP_BASE_DIGEST
    CADDY_VERSION      = CADDY_VERSION
    CADDY_SHA512_AMD64 = CADDY_SHA512_AMD64
    CADDY_SHA512_ARM64 = CADDY_SHA512_ARM64
  }
  labels = {
    # The same single source (versions.env) feeds the build ARGs above and these
    # runtime labels, so the baked image always records exactly what was built.
    "org.opencontainers.image.base.digest" = PHP_BASE_DIGEST
    "org.opencontainers.image.base.name"   = PHP_BASE
    "com.lumeweb.caddy.version"            = CADDY_VERSION
  }
  tags       = ["${REGISTRY}/pinner-php-caddy:${VERSION}"]
}

# wordpress: WordPress on Caddy/PHP-FPM, layered over php-caddy.
target "wordpress" {
  inherits   = ["_common"]
  context    = "images/wordpress"
  dockerfile = "Dockerfile"
  # Named context "base" is resolved to the php-caddy target's build result.
  # `FROM base` in the Dockerfile references this by name.
  contexts   = {
    base = "target:php-caddy"
  }
  args = {
    REGISTRY          = REGISTRY
    VERSION           = VERSION
    WORDPRESS_VERSION = WORDPRESS_VERSION
    WORDPRESS_SHA256  = WORDPRESS_SHA256
  }
  labels = {
    "org.opencontainers.image.base.digest" = PHP_BASE_DIGEST
    "org.opencontainers.image.base.name"   = PHP_BASE
    "com.lumeweb.wordpress.version"        = WORDPRESS_VERSION
  }
  tags       = ["${REGISTRY}/workspace-wordpress:${VERSION}"]
}

group "default" {
  targets = ["php-caddy", "wordpress"]
}
