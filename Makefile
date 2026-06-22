.PHONY: help build clean test test-parallel harden validate-docs \
	audit-default-linkage verify-pin verify verify-products \
	bootstrap-minilm build-minilm verify-minilm

PKFASTEMBED_PREFIX ?= $(CURDIR)/.build/pkfastembed
PK_MINILM_MODEL_DIR ?= $(CURDIR)/.build/minilm-model
export PKFASTEMBED_PREFIX
export PK_MINILM_MODEL_DIR

PRODUCTS := PKShared PKPrompt PositronicKit PKLocalEmbeddings \
	PKOpenRouterProvider PKOllamaProvider PKOpenAIProvider PositronicKitExamples

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
	@echo "  make verify                Run pin, docs, linkage, and test gates"
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
	@swift build --target PKLocalEmbeddings --verbose > .build/default-build.log 2>&1
	@! grep -E "libpkfastembed|-lpkfastembed|PKFastEmbed\.build|PKMiniLMTraitBackend\.build" .build/default-build.log

verify-pin:
	@echo "Checking MiniLM artifact pin consistency..."
	@bash Scripts/check-model-pin.sh

verify: verify-pin validate-docs audit-default-linkage test

verify-products:
	@set -e; for product in $(PRODUCTS); do \
		echo "Building $$product..."; \
		swift build --product "$$product"; \
	done

# Idempotent: verifies the pin, then downloads/checksums pinned assets and builds
# the native bridge only when missing. Safe to declare as a prerequisite so the
# MiniLM build/test pipeline prepares everything without a separate manual step.
bootstrap-minilm: verify-pin
	@bash Scripts/bootstrap-minilm-ci.sh

build-minilm: bootstrap-minilm
	@echo "Building MiniLM trait product..."
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		swift build --product PKLocalEmbeddings --traits MiniLMEmbeddings

verify-minilm: bootstrap-minilm
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		swift test --traits MiniLMEmbeddings --filter MiniLMEmbeddingContractTests
	@PKG_CONFIG_PATH="$(PKFASTEMBED_PREFIX)/lib/pkgconfig" \
		PK_MINILM_MODEL_DIR="$(PK_MINILM_MODEL_DIR)" \
		swift test --traits MiniLMEmbeddings --filter PKFastEmbedTests
