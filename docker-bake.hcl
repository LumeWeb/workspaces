variable "REGISTRY" { default = "ghcr.io/lumeweb" }
variable "VERSION"  { default = "0.1.0" }

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
  tags       = ["${REGISTRY}/pinner-wordpress:${VERSION}"]
}

group "default" {
  targets = ["php-caddy", "wordpress"]
}
