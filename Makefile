.PHONY: help build clean test test-parallel harden doctor validate-docs verify-doc-snippets \
	audit-default-linkage verify-pin verify verify-macos-default \
	verify-linux verify-linux-base verify-linux-current \
	verify-linux-asan \
	verify-products verify-examples verify-tests verify-pktestsupport verify-macos-minilm \
	bootstrap-minilm build-minilm verify-minilm \
	linux-image linux-build linux-test linux-test-scratch linux-test-filter require-container-runtime

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
LINUX_SCRATCH_DIR ?= $(CURDIR)/.build/linux-test-scratch
LINUX_TEST_TRAITS ?=
CONTAINER_RUNTIME ?= $(shell \
	if command -v podman >/dev/null 2>&1; then command -v podman; \
	elif command -v docker >/dev/null 2>&1; then command -v docker; \
	fi)
CONTAINER_IS_PODMAN := $(if $(filter podman podman-%,$(notdir $(CONTAINER_RUNTIME))),1,)
ifeq ($(CONTAINER_IS_PODMAN),1)
CONTAINER_USER_FLAGS := --userns=keep-id --user "$$(id -u):$$(id -g)"
else
CONTAINER_USER_FLAGS := --user "$$(id -u):$$(id -g)"
endif

# Library-product discovery is intentionally NOT done at parse time. It used to
# run `swift package describe` for almost every target, so `make help` (and
# unrelated targets) failed before execution whenever Swift or dependency
# resolution was unavailable (PKRR-026). Discovery now happens lazily inside
# the `verify-products` recipe below; per-product builds use the pattern rule
# so there is no parse-time `swift package describe`.

# Build a single library product by name, e.g. `make verify-product-PKShared`.
verify-product-%:
	@echo "Building $*..."
	@swift build --product "$*"

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
	@echo "  make verify-linux-current  Run the current Linux gate"
	@echo "  make verify-linux-asan     Run PKFastEmbed tests under Linux x86_64 AddressSanitizer"
	@echo "  make verify-products       Build every library product declared by Package.swift"
	@echo "  make verify-examples       Build the PositronicKitExamples executable"
	@echo "  make verify-tests          Run the test suite"
	@echo "  make verify-pktestsupport  Build PKTestSupport and an ordinary-import consumer in release mode"
	@echo "  make verify-pin            Check the pinned MiniLM artifact hashes are consistent"
	@echo "  make build-minilm          Prepare assets/native bridge and build the MiniLM trait product"
	@echo "  make verify-minilm         Prepare pinned assets and run MiniLM gates"
	@echo "  make doctor                Report missing prerequisites (Swift, Rust, container runtime, ...)"
	@echo ""
	@echo "Linux (Docker):"
	@echo "  make linux-image           Build the Linux development Docker image"
	@echo "  make linux-build           Build in a Linux container (bind-mounted)"
	@echo "  make linux-test            Run the full Linux gate in a container"
	@echo "  make linux-test-scratch    Run both Linux suites in a reusable isolated scratch"
	@echo "  make linux-test-filter LINUX_TEST_FILTER='…'  Run a focused Linux test in reusable scratch"

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

verify-doc-snippets:
	@echo "Syntax-checking Swift fenced blocks in docs/..."
	@bash Scripts/compile-doc-snippets.sh

audit-default-linkage:
	@echo "Auditing default Apple build for native MiniLM linkage..."
	@mkdir -p .build
	@swift build --product PKLocalEmbeddings --verbose > .build/default-build.log 2>&1
	@! grep -E "libpkfastembed|-lpkfastembed|PKFastEmbed\.build|PKMiniLMTraitBackend\.build" .build/default-build.log

verify-pin:
	@echo "Checking MiniLM artifact pin consistency..."
	@bash Scripts/check-model-pin.sh

# Preflight: report every prerequisite the Makefile gates depend on (Swift,
# Rust, C/C++ toolchain, pkg-config, OpenSSL, curl, shasum, container runtime,
# MiniLM model assets, host platform) with actionable hints for anything missing.
# Does not require Swift to run (parse-time discovery was removed in PKRR-026).
doctor:
	@bash Scripts/doctor.sh "$(CONTAINER_RUNTIME)" "$(PKFASTEMBED_PREFIX)"

verify-macos-default: verify

verify: verify-pin validate-docs verify-doc-snippets audit-default-linkage verify-products verify-examples verify-pktestsupport verify-tests

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
	if [ -z "$$products" ]; then \
		echo "verify-products: no library products discovered from Package.swift (is 'swift package describe' working?)" >&2; \
		exit 1; \
	fi; \
	for product in $$products; do \
		echo "Building $$product..."; \
		swift build --product "$$product"; \
	done

verify-examples:
	@echo "Building PositronicKitExamples..."
	@swift build --product PositronicKitExamples

verify-pktestsupport:
	@echo "Building PKTestSupport in release configuration..."
	@swift build -c release --product PKTestSupport
	@echo "Compiling an ordinary-import PKTestSupport consumer..."
	@swift build -c release --target PKTestSupportConsumer

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

# Fail fast with one clear message when no container runtime is configured,
# instead of a cryptic shell error from an empty $(CONTAINER_RUNTIME).
require-container-runtime:
	@if [ -z "$(CONTAINER_RUNTIME)" ]; then \
		echo "make: no container runtime found (neither podman nor docker on PATH, and CONTAINER_RUNTIME is empty)." >&2; \
		echo "    Install podman or docker, or set CONTAINER_RUNTIME=/path/to/runtime." >&2; \
		echo "    Run 'make doctor' for a full prerequisite check." >&2; \
		exit 1; \
	fi

# --- Linux Docker targets ----------------------------------------------------
# Bind-mount the checkout so host edits are immediately visible in the container.
# Build artifacts land in the host .build/ directory (gitignored).

linux-image: require-container-runtime
	@echo "Building Linux development image..."
	@$(CONTAINER_RUNTIME) build -t $(LINUX_IMAGE) -f .devcontainer/Dockerfile .

linux-build: require-container-runtime linux-image
	@echo "Building in Linux container..."
	@$(CONTAINER_RUNTIME) run --rm $(CONTAINER_USER_FLAGS) \
		-e HOME=/tmp -e CARGO_HOME=/tmp/cargo \
		-v "$(CURDIR):/workspace:Z" -w /workspace $(LINUX_IMAGE) \
		make build-minilm

linux-test: require-container-runtime linux-image
	@echo "Running Linux verification gate in container..."
	@$(CONTAINER_RUNTIME) run --rm $(CONTAINER_USER_FLAGS) \
		-e HOME=/tmp -e CARGO_HOME=/tmp/cargo \
		-v "$(CURDIR):/workspace:Z" -w /workspace $(LINUX_IMAGE) \
		make verify-linux-current

# Run both canonical Linux suites without using the checkout's shared SwiftPM
# build database. Reusing LINUX_SCRATCH_DIR makes subsequent gates much faster.
linux-test-scratch: require-container-runtime linux-image
	@mkdir -p "$(LINUX_SCRATCH_DIR)"
	@$(CONTAINER_RUNTIME) run --rm $(CONTAINER_USER_FLAGS) \
		-e HOME=/tmp -e CARGO_HOME=/tmp/cargo \
		-e PKFASTEMBED_PREFIX=/workspace/.build/pkfastembed \
		-e PKG_CONFIG_PATH=/workspace/.build/pkfastembed/lib/pkgconfig \
		-e LIBRARY_PATH=/workspace/.build/pkfastembed/lib \
		-e PK_MINILM_MODEL_DIR=/workspace/.build/minilm-model/$(MINILM_MODEL_SHA256) \
		-v "$(CURDIR):/workspace:Z" -v "$(LINUX_SCRATCH_DIR):/scratch:Z" \
		-w /workspace $(LINUX_IMAGE) \
		bash -lc 'make bootstrap-minilm && swift test --scratch-path /scratch --jobs 1 && swift test --scratch-path /scratch --jobs 1 --traits MiniLMEmbeddings'

# Run a focused Linux filter without contending for the checkout's shared
# .build/build.db. Set a unique LINUX_SCRATCH_DIR for concurrent invocations.
linux-test-filter: require-container-runtime linux-image
	@if [ -z "$(LINUX_TEST_FILTER)" ]; then \
		echo "make: LINUX_TEST_FILTER is required (for example: TestHTTPServerTests)." >&2; \
		exit 2; \
	fi
	@mkdir -p "$(LINUX_SCRATCH_DIR)"
	@$(CONTAINER_RUNTIME) run --rm $(CONTAINER_USER_FLAGS) \
			-e HOME=/tmp -e CARGO_HOME=/tmp/cargo \
			-e PKFASTEMBED_PREFIX=/workspace/.build/pkfastembed \
			-e PKG_CONFIG_PATH=/workspace/.build/pkfastembed/lib/pkgconfig \
			-e LIBRARY_PATH=/workspace/.build/pkfastembed/lib \
			-e PK_MINILM_MODEL_DIR=/workspace/.build/minilm-model/$(MINILM_MODEL_SHA256) \
			-e LINUX_TEST_FILTER="$(LINUX_TEST_FILTER)" \
			-e LINUX_TEST_TRAITS="$(LINUX_TEST_TRAITS)" \
			-v "$(CURDIR):/workspace:Z" -v "$(LINUX_SCRATCH_DIR):/scratch:Z" \
			-w /workspace $(LINUX_IMAGE) \
			bash -lc 'if [ -n "$$LINUX_TEST_TRAITS" ]; then swift test --scratch-path /scratch --jobs 1 --traits "$$LINUX_TEST_TRAITS" --filter "$$LINUX_TEST_FILTER"; else swift test --scratch-path /scratch --jobs 1 --filter "$$LINUX_TEST_FILTER"; fi'
