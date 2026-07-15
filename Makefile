.PHONY: help build clean test test-parallel harden validate-docs \
	audit-default-linkage verify-pin verify verify-macos-default \
	verify-linux verify-linux-base verify-linux-minimum verify-linux-current \
	verify-linux-asan \
	verify-products verify-examples verify-tests verify-macos-minilm \
	bootstrap-minilm build-minilm verify-minilm \
	linux-image linux-build linux-test

PKFASTEMBED_PREFIX ?= $(CURDIR)/.build/pkfastembed
PKFASTEMBED_ASAN_TOOLCHAIN ?= nightly
PKFASTEMBED_ASAN_TARGET ?= x86_64-unknown-linux-gnu
# Key the MiniLM cache root by the exact model.onnx checksum so stale assets
# cannot leak across revisions when CI reuses build storage.
MINILM_MODEL_CACHE_ROOT ?= $(CURDIR)/.build/minilm-model
MINILM_MODEL_SHA256 := $(shell awk '$$2 == "model.onnx" { print $$1 }' native/pkfastembed/model-assets.sha256)
ifeq ($(strip $(MINILM_MODEL_SHA256)),)
$(error Could not derive the MiniLM model checksum from native/pkfastembed/model-assets.sha256)
endif
MINILM_MODEL_CACHE_DIR := $(MINILM_MODEL_CACHE_ROOT)/$(MINILM_MODEL_SHA256)
PK_MINILM_MODEL_DIR ?= $(MINILM_MODEL_CACHE_DIR)
export PKFASTEMBED_PREFIX
export PK_MINILM_MODEL_DIR

LINUX_IMAGE ?= positronickit-linux-dev

ifeq ($(filter linux-image linux-build linux-test,$(MAKECMDGOALS)),)
PRODUCTS := $(shell swift package describe --type json | swift Scripts/list-library-products.swift)
PRODUCT_VERIFY_TARGETS := $(addprefix verify-product-,$(PRODUCTS))

define product_verify_rule
verify-product-$(1):
	@echo "Building $(1)..."
	@swift build --product "$(1)"
endef
$(foreach product,$(PRODUCTS),$(eval $(call product_verify_rule,$(product))))
.PHONY: $(PRODUCT_VERIFY_TARGETS)
endif

# Default target
help:
	@echo "PositronicKit - Development Commands"
	@echo ""
	@echo "Build & Run:"
	@echo "  make build                 Build the project"
	@echo "  make clean                 Clean build artifacts"
	@echo ""
	@echo "Development:"
	@echo "  make test                  Run tests"
	@echo "  make test-parallel         Run tests in parallel"
	@echo "  make harden                Run build and parallel hardening test gate"
	@echo "  make verify                Run pin, docs, linkage, products, examples, and test gates (macOS)"
	@echo "  make verify-macos-default  Run the default macOS gate"
	@echo "  make verify-macos-minilm   Run the MiniLM macOS gate"
	@echo "  make verify-linux          Run the current Linux gate"
	@echo "  make verify-linux-base     Run the shared Linux verification body"
	@echo "  make verify-linux-minimum  Run the minimum Linux gate"
	@echo "  make verify-linux-current  Run the current Linux gate"
	@echo "  make verify-linux-asan     Run PKFastEmbed tests under Linux x86_64 AddressSanitizer"
	@echo "  make verify-products       Build every library product declared by Package.swift"
	@echo "  make verify-examples       Build the PositronicKitExamples executable"
	@echo "  make verify-tests          Run the test suite"
	@echo "  make verify-pin            Check the pinned MiniLM artifact hashes are consistent"
	@echo "  make build-minilm          Prepare assets/native bridge and build the MiniLM trait product"
	@echo "  make verify-minilm         Prepare pinned assets and run MiniLM gates"
	@echo ""
	@echo "Linux (Docker):"
	@echo "  make linux-image           Build the Linux development Docker image"
	@echo "  make linux-build           Build in a Linux container (bind-mounted)"
	@echo "  make linux-test            Run the full Linux gate in a container"

build:
	@echo "Building PositronicKit..."
	@swift build

clean:
	@echo "Cleaning build artifacts..."
	@rm -rf DerivedData
	@rm -rf .build
	@rm -rf build
	@echo "Clean complete!"

test:
	@echo "Running tests..."
	@swift test

test-parallel:
	@echo "Running tests in parallel..."
	@swift test --parallel --num-workers 2

harden:
	@echo "Running hardening gate..."
	@swift build
	@swift test --parallel --num-workers 2

validate-docs:
	@bash Scripts/validate-docs.sh

audit-default-linkage:
	@echo "Auditing default Apple build for native MiniLM linkage..."
	@mkdir -p .build
	@swift build --product PKLocalEmbeddings --verbose > .build/default-build.log 2>&1
	@! grep -E "libpkfastembed|-lpkfastembed|PKFastEmbed\.build|PKMiniLMTraitBackend\.build" .build/default-build.log

verify-pin:
	@echo "Checking MiniLM artifact pin consistency..."
	@bash Scripts/check-model-pin.sh

verify-macos-default: verify

verify: verify-pin validate-docs audit-default-linkage verify-products verify-examples verify-tests

verify-linux-base: bootstrap-minilm
	@echo "Running comprehensive Linux test suite..."
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		LIBRARY_PATH="$(PKFASTEMBED_PREFIX)/lib$${LIBRARY_PATH:+:$$LIBRARY_PATH}" \
		PK_MINILM_MODEL_DIR="$(MINILM_MODEL_CACHE_DIR)" \
		swift test
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		LIBRARY_PATH="$(PKFASTEMBED_PREFIX)/lib$${LIBRARY_PATH:+:$$LIBRARY_PATH}" \
		PK_MINILM_MODEL_DIR="$(MINILM_MODEL_CACHE_DIR)" \
		swift test --traits MiniLMEmbeddings

verify-linux-minimum: verify-linux-base

verify-linux-current: verify-linux-base

verify-linux: verify-linux-current

verify-linux-asan:
	@echo "Running PKFastEmbed tests under AddressSanitizer for $(PKFASTEMBED_ASAN_TARGET)..."
	@echo "Requires rustup toolchain '$(PKFASTEMBED_ASAN_TOOLCHAIN)' with rust-src installed."
	@cd native/pkfastembed && \
		ASAN_OPTIONS="$${ASAN_OPTIONS:-detect_leaks=1}" \
		RUSTFLAGS="$${RUSTFLAGS:+$$RUSTFLAGS }-Zsanitizer=address" \
		RUSTDOCFLAGS="$${RUSTDOCFLAGS:+$$RUSTDOCFLAGS }-Zsanitizer=address" \
		cargo +$(PKFASTEMBED_ASAN_TOOLCHAIN) test -Zbuild-std --target $(PKFASTEMBED_ASAN_TARGET)

verify-macos-minilm: verify-minilm

verify-products:
	@set -eu; \
	products="$$(swift package describe --type json | swift Scripts/list-library-products.swift)"; \
	for product in $$products; do \
		echo "Building $$product..."; \
		swift build --product "$$product"; \
	done

verify-examples:
	@echo "Building PositronicKitExamples..."
	@swift build --product PositronicKitExamples

verify-tests: test

# Idempotent: verifies the pin, then downloads/checksums pinned assets and builds
# the native bridge only when missing. Safe to declare as a prerequisite so the
# MiniLM build/test pipeline prepares everything without a separate manual step.
bootstrap-minilm: verify-pin
	@bash Scripts/bootstrap-minilm-ci.sh

build-minilm: bootstrap-minilm
	@echo "Building MiniLM trait product..."
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		LIBRARY_PATH="$(PKFASTEMBED_PREFIX)/lib$${LIBRARY_PATH:+:$$LIBRARY_PATH}" \
		swift build --traits MiniLMEmbeddings

verify-minilm: bootstrap-minilm
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		LIBRARY_PATH="$(PKFASTEMBED_PREFIX)/lib$${LIBRARY_PATH:+:$$LIBRARY_PATH}" \
		PK_MINILM_MODEL_DIR="$(MINILM_MODEL_CACHE_DIR)" \
		swift test --traits MiniLMEmbeddings --filter MiniLMEmbeddingContractTests
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		LIBRARY_PATH="$(PKFASTEMBED_PREFIX)/lib$${LIBRARY_PATH:+:$$LIBRARY_PATH}" \
		PK_MINILM_MODEL_DIR="$(MINILM_MODEL_CACHE_DIR)" \
		swift test --traits MiniLMEmbeddings --filter PKFastEmbedTests

# --- Linux Docker targets ----------------------------------------------------
# Bind-mount the checkout so host edits are immediately visible in the container.
# Build artifacts land in the host .build/ directory (gitignored).

linux-image:
	@echo "Building Linux development image..."
	@docker build -t $(LINUX_IMAGE) -f .devcontainer/Dockerfile .

linux-build: linux-image
	@echo "Building in Linux container..."
	@docker run --rm --user "$$(id -u):$$(id -g)" \
		-e HOME=/tmp -e CARGO_HOME=/tmp/cargo \
		-v "$(CURDIR):/workspace:Z" -w /workspace $(LINUX_IMAGE) \
		swift build

linux-test: linux-image
	@echo "Running Linux verification gate in container..."
	@docker run --rm --user "$$(id -u):$$(id -g)" \
		-e HOME=/tmp -e CARGO_HOME=/tmp/cargo \
		-v "$(CURDIR):/workspace:Z" -w /workspace $(LINUX_IMAGE) \
		make verify-linux-current
