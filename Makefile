.PHONY: help build clean test test-parallel harden validate-docs \
	audit-default-linkage verify-pin verify verify-macos-default \
	verify-linux verify-linux-base verify-linux-minimum verify-linux-current \
	verify-products verify-macos-minilm \
	bootstrap-minilm build-minilm verify-minilm

PKFASTEMBED_PREFIX ?= $(CURDIR)/.build/pkfastembed
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

PRODUCTS := PKShared PKPrompt PositronicKit PKLocalEmbeddings \
	PKOpenRouterProvider PKOllamaProvider PKOpenAIProvider PositronicKitExamples
PRODUCT_VERIFY_TARGETS := $(addprefix verify-product-,$(PRODUCTS))

define product_verify_rule
verify-product-$(1):
	@echo "Building $(1)..."
	@swift build --product "$(1)"
endef
$(foreach product,$(PRODUCTS),$(eval $(call product_verify_rule,$(product))))
.PHONY: $(PRODUCT_VERIFY_TARGETS)

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
	@echo "  make verify                Run pin, docs, linkage, and test gates (macOS)"
	@echo "  make verify-macos-default  Run the default macOS gate"
	@echo "  make verify-macos-minilm   Run the MiniLM macOS gate"
	@echo "  make verify-linux          Run the current Linux gate"
	@echo "  make verify-linux-base     Run the shared Linux verification body"
	@echo "  make verify-linux-minimum  Run the minimum Linux gate"
	@echo "  make verify-linux-current  Run the current Linux gate"
	@echo "  make verify-products       Build every product on the current host"
	@echo "  make verify-pin            Check the pinned MiniLM artifact hashes are consistent"
	@echo "  make build-minilm          Prepare assets/native bridge and build the MiniLM trait product"
	@echo "  make verify-minilm         Prepare pinned assets and run MiniLM gates"

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

verify-macos-default: verify-pin validate-docs audit-default-linkage test

verify: verify-macos-default

verify-linux-base: bootstrap-minilm
	@echo "Running comprehensive Linux test suite..."
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		PK_MINILM_MODEL_DIR="$(MINILM_MODEL_CACHE_DIR)" \
		swift test
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		PK_MINILM_MODEL_DIR="$(MINILM_MODEL_CACHE_DIR)" \
		swift test --traits MiniLMEmbeddings

verify-linux-minimum: verify-linux-base

verify-linux-current: verify-linux-base

verify-linux: verify-linux-current

verify-macos-minilm: verify-minilm

verify-products: $(PRODUCT_VERIFY_TARGETS)

# Idempotent: verifies the pin, then downloads/checksums pinned assets and builds
# the native bridge only when missing. Safe to declare as a prerequisite so the
# MiniLM build/test pipeline prepares everything without a separate manual step.
bootstrap-minilm: verify-pin
	@bash Scripts/bootstrap-minilm-ci.sh

build-minilm: bootstrap-minilm
	@echo "Building MiniLM trait product..."
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		swift build --traits MiniLMEmbeddings

verify-minilm: bootstrap-minilm
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		PK_MINILM_MODEL_DIR="$(MINILM_MODEL_CACHE_DIR)" \
		swift test --traits MiniLMEmbeddings --filter MiniLMEmbeddingContractTests
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		PK_MINILM_MODEL_DIR="$(MINILM_MODEL_CACHE_DIR)" \
		swift test --traits MiniLMEmbeddings --filter PKFastEmbedTests
