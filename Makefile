SHELL := /bin/bash
.DEFAULT_GOAL := help

BAKE          ?= docker buildx bake
HADOLINT      ?= hadolint

# -- Release vs local image references ---------------------------------------
# REGISTRY/VERSION are the *release* namespace (GHCR) and recipe version. They
# are consumed ONLY by the CD release path: .github/workflows/release.yml runs
# `docker buildx bake --push`, which pushes the bake default tags derived below
# (see docker-bake.hcl `target "php-caddy"/"wordpress" .. tags`). Local build /
# verify NEVER touch these — a local run must require no registry access or
# authentication.
REGISTRY ?= ghcr.io/lumeweb
VERSION  ?= 0.1.0
RELEASE_PHP_CADDY_IMAGE ?= $(REGISTRY)/pinner-php-caddy:$(VERSION)
RELEASE_WORDPRESS_IMAGE ?= $(REGISTRY)/workspace-wordpress:$(VERSION)

# Local-only verification references. `make build` builds these tags and loads
# them into the local docker daemon (`--load`), so Compose and the verification
# scripts start them without ever pulling a (possibly private, authenticated)
# GHCR image. They are intentionally NOT registry-qualified.
PHP_CADDY_IMAGE ?= pinner-php-caddy:local
WORDPRESS_IMAGE ?= workspace-wordpress:local

# -- Pinned upstream inputs ---------------------------------------------------
# Single authoritative source for every upstream pin. Make loads them into the
# variables below, exports them, and bake reads them back from the process
# environment — so the exact values flow into the Docker build ARGs and the
# runtime OCI labels. The Dockerfiles declare these ARGs with NO hardcoded
# *production* defaults: the real pins live only in versions.env (single source
# of truth), while the php-caddy FROM ARGs carry a deliberately unresolvable
# non-production placeholder that fails the build fast if bake ever forgets to
# inject them. Bump by editing versions.env, then `make verify-pins` + the
# build/verify matrix.
include images/php-caddy/versions.env
include images/wordpress/versions.env
export PHP_BASE PHP_BASE_DIGEST CADDY_VERSION \
       CADDY_SHA512_AMD64 CADDY_SHA512_ARM64 \
       WORDPRESS_VERSION WORDPRESS_SHA256 \
       WP_CLI_VERSION WP_CLI_SHA512 \
       GO_BASE GO_BASE_DIGEST \
       COMPOSER_BASE COMPOSER_BASE_DIGEST

.PHONY: help build build-php-caddy build-wordpress \
        lint shellcheck hadolint \
        verify verify-php-caddy verify-workspace-init verify-wordpress deps-verify verify-pins clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

## -- building -------------------------------------------------------------

build: ## Build + load all images locally for the current platform
	# --load imports the built targets into the local docker daemon (required
	# under the docker-container buildx driver, which otherwise leaves them in
	# the build cache and emits a "No output specified" warning). The local
	# Compose verification then starts them without any registry access.
	$(BAKE) --load \
	        --set 'php-caddy.tags=$(PHP_CADDY_IMAGE)' \
	        --set 'wordpress.tags=$(WORDPRESS_IMAGE)' \
	        php-caddy wordpress

build-php-caddy: ## Build + load only the php-caddy base image locally
	$(BAKE) --load --set 'php-caddy.tags=$(PHP_CADDY_IMAGE)' php-caddy

# Builds the base first (as a bake target dependency) then the app image.
build-wordpress: ## Build + load only the WordPress image locally (base built as dependency)
	$(BAKE) --load --set 'wordpress.tags=$(WORDPRESS_IMAGE)' wordpress

## -- lint -----------------------------------------------------------------

lint: shellcheck hadolint ## Run all available linters

shellcheck: ## ShellCheck all shell scripts (warning+ severities)
	shellcheck -S warning images/*/*.sh scripts/*.sh

hadolint: ## Hadolint all Dockerfiles (skips if not installed)
	@if command -v $(HADOLINT) >/dev/null 2>&1; then \
		$(HADOLINT) --failure-threshold=error images/*/Dockerfile; \
	else \
		echo "hadolint not installed; skipping (install to enable)."; \
	fi

## -- verification ---------------------------------------------------------

verify: build verify-php-caddy verify-workspace-init verify-wordpress ## Build and run the full local verification matrix

verify-php-caddy: build-php-caddy ## Verify the php-caddy base image locally
	bash scripts/verify-php-caddy.sh --image $(PHP_CADDY_IMAGE)

# Unit tests for the workspace-init Go CLI (portal API-key exchange -> email).
verify-workspace-init:
	cd images/wordpress/workspace-init && gofmt -l . && go vet ./... && go test ./...

verify-wordpress: build-wordpress ## Verify the WordPress image locally (Compose + MariaDB)
	WORDPRESS_IMAGE=$(WORDPRESS_IMAGE) bash scripts/verify-wordpress.sh

## -- misc -----------------------------------------------------------------

deps-verify: ## Verify pinned upstream checksums (+ bake args match versions.env)
	bash scripts/verify-pins.sh

verify-pins: deps-verify ## Alias for deps-verify (verify upstream pins + no drift)

clean: ## Tear down any leftover verification containers/volumes
	docker compose -f compose/wordpress.local.yaml down -v --remove-orphans 2>/dev/null || true
