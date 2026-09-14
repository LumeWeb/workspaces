SHELL := /bin/bash
.DEFAULT_GOAL := help

REGISTRY      ?= ghcr.io/lumeweb
VERSION       ?= 0.1.0
BAKE          ?= docker buildx bake
HADOLINT      ?= hadolint

# -- Pinned upstream inputs ---------------------------------------------------
# Single authoritative source for every upstream pin. Make loads them into the
# variables below, exports them, and bake reads them back from the process
# environment — so the exact values flow into the Docker build ARGs and the
# runtime OCI labels. The Dockerfiles declare these ARGs with NO hardcoded
# defaults, so a value exists in exactly one place and cannot drift. Bump by
# editing versions.env, then `make verify-pins` + the build/verify matrix.
include images/php-caddy/versions.env
include images/wordpress/versions.env
export PHP_BASE PHP_BASE_DIGEST CADDY_VERSION \
       CADDY_SHA512_AMD64 CADDY_SHA512_ARM64 \
       WORDPRESS_VERSION WORDPRESS_SHA256


# Image references produced by `make build` (on the current platform). These
# are the same references the local Compose verification consumes.
PHP_CADDY_IMAGE ?= $(REGISTRY)/pinner-php-caddy:$(VERSION)
WORDPRESS_IMAGE ?= $(REGISTRY)/pinner-wordpress:$(VERSION)

.PHONY: help build build-php-caddy build-wordpress \
        lint shellcheck hadolint \
        verify verify-php-caddy verify-wordpress deps-verify verify-pins clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

## -- building -------------------------------------------------------------

build: ## Build all images for the current platform
	$(BAKE) --set 'php-caddy.tags=$(PHP_CADDY_IMAGE)' \
	        --set 'wordpress.tags=$(WORDPRESS_IMAGE)' \
	        php-caddy wordpress

build-php-caddy: ## Build only the php-caddy base image
	$(BAKE) --set 'php-caddy.tags=$(PHP_CADDY_IMAGE)' php-caddy

# Builds the base first (as a bake target dependency) then the app image.
build-wordpress: ## Build only the WordPress image (base built as dependency)
	$(BAKE) --set 'wordpress.tags=$(WORDPRESS_IMAGE)' wordpress

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

verify: build verify-php-caddy verify-wordpress ## Build and run the full local verification matrix

verify-php-caddy: build-php-caddy ## Verify the php-caddy base image locally
	bash scripts/verify-php-caddy.sh --image $(PHP_CADDY_IMAGE)

verify-wordpress: build-wordpress ## Verify the WordPress image locally (Compose + MariaDB)
	WORDPRESS_IMAGE=$(WORDPRESS_IMAGE) bash scripts/verify-wordpress.sh

## -- misc -----------------------------------------------------------------

deps-verify: ## Verify pinned upstream checksums (+ bake args match versions.env)
	bash scripts/verify-pins.sh

verify-pins: deps-verify ## Alias for deps-verify (verify upstream pins + no drift)

clean: ## Tear down any leftover verification containers/volumes
	docker compose -f compose/wordpress.local.yaml down -v --remove-orphans 2>/dev/null || true
