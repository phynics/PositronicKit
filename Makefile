.PHONY: help build clean test test-parallel harden doctor validate-docs verify-documentation verify-doc-snippets \
	verify verify-concurrency-scan verify-runtime-architecture verify-macos-default \
	verify-linux verify-linux-agent verify-linux-base verify-linux-current verify-linux-filter \
	verify-linux-scratch verify-linux-suites \
	verify-agent-harness verify-products verify-examples verify-tests verify-pktestsupport verify-public-consumers verify-dependency-direction verify-v4-vocabulary \
	verify-public-api update-public-api-baseline verify-release \
	agent-verify agent-test linux-image linux-build linux-test linux-test-scratch \
	linux-test-filter require-podman

LINUX_IMAGE ?= positronickit-linux-dev
LINUX_SCRATCH_DIR ?= $(CURDIR)/.build/agent-scratch/swift-6.3.3
LINUX_TEST_TRAITS ?=
AGENT_LOG_DIR ?= $(CURDIR)/.build/agent-logs
AGENT_LOCK_FILE ?= $(CURDIR)/.build/positronickit-agent-gate.lock
PODMAN ?= $(shell command -v podman 2>/dev/null)
FILTER ?=
TRAITS ?=
# Keep the repository's build and test gates strict without embedding unsafe
# compiler flags in Package.swift, which would affect downstream consumers.
SWIFT_BUILD_FLAGS ?= -Xswiftc -warnings-as-errors
export SWIFT_BUILD_FLAGS

# Build a single library product by name, e.g. `make verify-product-PKContracts`.
verify-product-%:
	@echo "Building $*..."
	@swift build $(SWIFT_BUILD_FLAGS) --target "$*"

# Default target
help:
	@echo "PositronicKit - Development Commands"
	@echo ""
	@echo "Build & Run:"
	@echo "  make build                 Build the project"
	@echo "  make clean                 Clean build artifacts"
	@echo ""
	@echo "Development:"
	@echo "  make agent-verify          Canonical full gate (Podman-only on Linux)"
	@echo "  make agent-test FILTER='…' Run a focused Podman Linux test"
	@echo "  make test                  Run tests"
	@echo "  make test-parallel         Run tests in parallel"
	@echo "  make harden                Run build and parallel hardening test gate"
	@echo "  make verify                Run docs, linkage, products, examples, and test gates (macOS)"
	@echo "  make verify-concurrency-scan Run the concurrency inline-annotation scan"
	@echo "  make verify-runtime-architecture Check enforced runtime ownership seams"
	@echo "  make verify-macos-default  Run the default macOS gate"
	@echo "  make verify-linux          Run the current Linux gate"
	@echo "  make verify-linux-base     Run the shared Linux verification body"
	@echo "  make verify-linux-current  Run the current Linux gate"
	@echo "  make verify-products       Build every library product declared by Package.swift"
	@echo "  make verify-examples       Build the PositronicKitExamples executable"
	@echo "  make verify-tests          Run the test suite"
	@echo "  make verify-pktestsupport  Build PKTestSupport and an ordinary-import consumer in release mode"
	@echo "  make verify-public-consumers  Compile ordinary imports for every public library product"
	@echo "  make verify-public-api    Compare public Swift symbols with the reviewed Next / v5 baseline"
	@echo "  make update-public-api-baseline  Record an intentionally reviewed public API change"
	@echo "  make verify-release VERSION=x.y.z  Check local tag and release artifacts agree"
	@echo "  make verify-dependency-direction  Check the v4 target dependency boundaries"
	@echo "  make verify-v4-vocabulary  Check the v4 Thread/Turn/Agent vocabulary"
	@echo "  make verify-documentation  Check docs catalog, navigation, links, pins, products, and vocabulary"
	@echo "  make verify-agent-harness Run agent test-entrypoint regression tests"
	@echo "  make doctor                Report missing prerequisites (Swift, container runtime, ...)"
	@echo ""
	@echo "Linux (Podman):"
	@echo "  make linux-image           Build the Linux development Podman image"
	@echo "  make linux-build           Build in a Linux container (bind-mounted)"
	@echo "  make linux-test            Run the full Linux gate in a container"
	@echo "  make linux-test-scratch    Run both Linux suites in a reusable isolated scratch"
	@echo "  make linux-test-filter LINUX_TEST_FILTER='…'  Run a focused Linux test in reusable scratch"

build:
	@echo "Building PositronicKit..."
	@swift build $(SWIFT_BUILD_FLAGS)

clean:
	@echo "Cleaning build artifacts..."
	@rm -rf DerivedData
	@rm -rf .build
	@rm -rf build
	@echo "Clean complete!"

test:
	@echo "Running tests..."
	@swift test $(SWIFT_BUILD_FLAGS)

test-parallel:
	@echo "Running tests in parallel..."
	@swift test $(SWIFT_BUILD_FLAGS) --parallel --num-workers 2

harden:
	@echo "Running hardening gate..."
	@swift build $(SWIFT_BUILD_FLAGS)
	@swift test $(SWIFT_BUILD_FLAGS) --parallel --num-workers 2

validate-docs: verify-documentation
	@bash Scripts/validate-docs.sh

verify-documentation:
	@python3 Scripts/generate-doc-navigation.py --check
	@python3 Scripts/validate-documentation.py
	@bash Scripts/check-v4-vocabulary.sh
	@bash Scripts/compile-doc-snippets.sh

verify-doc-snippets:
	@echo "Syntax-checking Swift fenced blocks in docs/..."
	@bash Scripts/compile-doc-snippets.sh

# Enforce the concurrency exception manifest: fail on any un-annotated
# @unchecked Sendable, NSLock, stored continuation/task, or Box-named holder.
# Global custom rules live in .swiftlint.yml; every reviewed occurrence must
# carry an inline // swiftlint:disable:this annotation matching
# docs/Concurrency/exception-manifest.md.
verify-concurrency-scan:
	@echo "Running concurrency guardrail scan..."
	@swiftlint lint --strict

verify-runtime-architecture:
	@python3 Scripts/migrate-turn-execution-request.py --check

# Preflight: report every prerequisite the Makefile gates depend on (Swift,
# OpenSSL, curl, shasum, container runtime, host platform) with actionable hints for anything missing.
doctor:
	@bash Scripts/doctor.sh "$(PODMAN)"

verify-macos-default: verify

verify: verify-concurrency-scan verify-runtime-architecture verify-dependency-direction validate-docs verify-products verify-public-api verify-examples verify-pktestsupport verify-public-consumers verify-tests

verify-linux-suites:
	@echo "Running comprehensive Linux test suite..."
	@swift test $(SWIFT_BUILD_FLAGS)

verify-linux-base:
	@$(MAKE) verify-linux-suites

verify-linux-current: verify-linux-base

verify-linux: verify-linux-current

# The inner Linux gate used by both GitHub Actions and the outer Podman agent
# entrypoint. Native-linker discovery is exported once for every product,
# example, support, and test command so callers cannot accidentally omit it.
verify-linux-agent:
	@echo "Running agent/CI Linux verification contract..."
	@$(MAKE) verify-agent-harness verify-runtime-architecture verify-dependency-direction verify-documentation verify-products verify-public-api verify-examples verify-pktestsupport verify-public-consumers verify-linux-suites

verify-linux-filter:
	@if [ -z "$(LINUX_TEST_FILTER)" ]; then \
		echo "make: LINUX_TEST_FILTER is required." >&2; \
		exit 2; \
	fi
	@if [ -n "$(LINUX_TEST_TRAITS)" ]; then \
		swift test $(SWIFT_BUILD_FLAGS) --scratch-path /scratch --jobs 1 --traits "$(LINUX_TEST_TRAITS)" --filter "$(LINUX_TEST_FILTER)"; \
	else \
		swift test $(SWIFT_BUILD_FLAGS) --scratch-path /scratch --jobs 1 --filter "$(LINUX_TEST_FILTER)"; \
	fi

verify-linux-scratch:
	@swift test $(SWIFT_BUILD_FLAGS) --scratch-path /scratch --jobs 1

verify-products:
	@set -eu; \
	products="$$(swift package describe --type json | swift Scripts/list-library-products.swift)"; \
	if [ -z "$$products" ]; then \
		echo "verify-products: no library products discovered from Package.swift (is 'swift package describe' working?)" >&2; \
		exit 1; \
	fi; \
	for product in $$products; do \
		echo "Building $$product..."; \
		swift build $(SWIFT_BUILD_FLAGS) --target "$$product"; \
	done

verify-examples:
	@echo "Building PositronicKitExamples..."
	@swift build $(SWIFT_BUILD_FLAGS) --product PositronicKitExamples

verify-pktestsupport:
	@echo "Building PKTestSupport in release configuration..."
	@swift build $(SWIFT_BUILD_FLAGS) -c release --target PKTestSupport
	@echo "Compiling an ordinary-import PKTestSupport consumer..."
	@swift build $(SWIFT_BUILD_FLAGS) -c release --target PKTestSupportConsumer

verify-public-consumers:
	@echo "Compiling ordinary imports for every public library product..."
	@swift build $(SWIFT_BUILD_FLAGS) -c release --target PublicProductConsumer

verify-public-api:
	@python3 Scripts/public-api-baseline.py --check

update-public-api-baseline:
	@python3 Scripts/public-api-baseline.py --write

verify-release:
	@python3 Scripts/validate-release-readiness.py "$(VERSION)"

verify-dependency-direction:
	@bash Scripts/check-dependency-direction.sh

verify-v4-vocabulary:
	@bash Scripts/check-v4-vocabulary.sh

verify-tests: test

verify-agent-harness:
	@bash Tests/Scripts/doctor_test.sh
	@bash Tests/Scripts/run_linux_container_test.sh
	@bash Tests/Scripts/public_api_baseline_test.sh

# Linux testing intentionally has no native or Docker fallback. The shared
# runner performs the deeper access check and prints the sandbox-escalation
# remediation when Podman is installed but unavailable.
require-podman:
	@if [ -z "$(PODMAN)" ]; then \
		echo "make: PositronicKit Linux testing requires Podman." >&2; \
		echo "    Install Podman or set PODMAN=/absolute/path/to/podman." >&2; \
		echo "    Run 'make doctor' for a full prerequisite check." >&2; \
		exit 1; \
	fi

# --- Linux Podman targets ----------------------------------------------------
# Bind-mount the checkout so host edits are immediately visible in the container.
# Build artifacts land in the host .build/ directory (gitignored).

agent-verify: require-podman
	@mkdir -p "$(AGENT_LOG_DIR)"
	@PODMAN="$(PODMAN)" LINUX_IMAGE="$(LINUX_IMAGE)" \
		bash Scripts/run-linux-container.sh \
		--log "$(AGENT_LOG_DIR)/verify.log" \
		--lock "$(AGENT_LOCK_FILE)" \
		-- make verify-linux-agent

agent-test: require-podman
	@if [ -z "$(FILTER)" ]; then \
		echo "make: FILTER is required (for example: make agent-test FILTER='MessageContentTests')." >&2; \
		exit 2; \
	fi
	@mkdir -p "$(AGENT_LOG_DIR)" "$(LINUX_SCRATCH_DIR)"
	@PODMAN="$(PODMAN)" LINUX_IMAGE="$(LINUX_IMAGE)" \
		LINUX_TEST_FILTER="$(FILTER)" LINUX_TEST_TRAITS="$(TRAITS)" \
		bash Scripts/run-linux-container.sh \
		--log "$(AGENT_LOG_DIR)/test.log" \
		--lock "$(AGENT_LOCK_FILE)" \
		--scratch "$(LINUX_SCRATCH_DIR)" \
		-- make verify-linux-filter

linux-image: require-podman
	@PODMAN="$(PODMAN)" LINUX_IMAGE="$(LINUX_IMAGE)" \
		bash Scripts/run-linux-container.sh --build-only

linux-build: require-podman
	@PODMAN="$(PODMAN)" LINUX_IMAGE="$(LINUX_IMAGE)" \
		bash Scripts/run-linux-container.sh --lock "$(AGENT_LOCK_FILE)" -- make build

linux-test: agent-verify

# Run both canonical Linux suites without using the checkout's shared SwiftPM
# build database. Reusing LINUX_SCRATCH_DIR makes subsequent gates much faster.
linux-test-scratch: require-podman
	@mkdir -p "$(LINUX_SCRATCH_DIR)"
	@PODMAN="$(PODMAN)" LINUX_IMAGE="$(LINUX_IMAGE)" \
		bash Scripts/run-linux-container.sh \
		--lock "$(AGENT_LOCK_FILE)" \
		--scratch "$(LINUX_SCRATCH_DIR)" \
		-- make verify-linux-scratch

# Run a focused Linux filter without contending for the checkout's shared
# .build/build.db. Set a unique LINUX_SCRATCH_DIR for concurrent invocations.
linux-test-filter:
	@if [ -z "$(LINUX_TEST_FILTER)" ]; then \
		echo "make: LINUX_TEST_FILTER is required (for example: TestHTTPServerTests)." >&2; \
		exit 2; \
	fi
	@$(MAKE) agent-test FILTER="$(LINUX_TEST_FILTER)" TRAITS="$(LINUX_TEST_TRAITS)"
