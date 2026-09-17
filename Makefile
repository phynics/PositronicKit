.PHONY: help build clean test test-fast doctor validate-docs verify-documentation \
	verify verify-concurrency-scan verify-runtime-architecture \
	verify-linux-agent verify-linux-filter verify-linux-repeat verify-linux-coverage \
	verify-agent-harness verify-products verify-examples verify-pktestsupport verify-public-consumers verify-dependency-direction verify-test-layout verify-gate-script-coverage verify-story-coverage verify-v4-vocabulary verify-doc-snippets detect-flakes \
	verify-public-api update-public-api-baseline verify-release \
	agent-verify agent-test agent-test-repeat linux-image linux-build linux-coverage require-container-runtime

# Swift toolchain baked into the supported Linux development image.
LINUX_SWIFT_VERSION ?= 6.4.0
LINUX_IMAGE ?= positronickit-linux-dev-$(LINUX_SWIFT_VERSION)
# `agent-test` and `linux-coverage` isolate their SwiftPM scratch per toolchain.
# `agent-verify` and `linux-build` use the bind-mounted checkout `.build`, so
# remove that directory before switching LINUX_SWIFT_VERSION.
LINUX_SCRATCH_DIR ?= $(CURDIR)/.build/agent-scratch/swift-$(LINUX_SWIFT_VERSION)
LINUX_COVERAGE_SCRATCH_DIR ?= $(CURDIR)/.build/linux-coverage-scratch/swift-$(LINUX_SWIFT_VERSION)
LINUX_TEST_TRAITS ?=
# Per-test repetition count for `verify-linux-repeat` / `agent-test-repeat`.
LINUX_TEST_REPETITIONS ?=
AGENT_LOG_DIR ?= $(CURDIR)/.build/agent-logs
AGENT_LOCK_FILE ?= $(CURDIR)/.build/positronickit-agent-gate.lock
# Podman is preferred; Docker is an equally supported alternative. Set
# CONTAINER_RUNTIME to pin an explicit binary and skip auto-detection.
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
FILTER ?=
TRAITS ?=
# Per-test repetition count for `agent-test-repeat FILTER='…' N=…`.
N ?=
# Inner-loop selection for `make test-fast`. This regex is generated from the
# source tags and stable test names. It includes the untagged module test
# targets and excludes runtime integration/slow suites.
FAST_FILTER ?= $(shell python3 Scripts/generate-test-fast-filter.py)
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
	@echo "  make agent-verify          Canonical full gate (container-only on Linux)"
	@echo "  make agent-test FILTER='…' Run a focused containerized Linux test"
	@echo "  make agent-test-repeat FILTER='…' N=…  Repeat a focused test N times for flake detection"
	@echo "  make linux-coverage         Generate Linux llvm-cov reports in .build/linux-coverage"
	@echo "  make test                  Run tests"
	@echo "  make test-fast             Run generated fast test filter"
	@echo "  make verify                Run docs, linkage, products, examples, and test gates (macOS)"
	@echo "  make verify-concurrency-scan Run the concurrency inline-annotation scan"
	@echo "  make verify-runtime-architecture Check enforced runtime ownership seams"
	@echo "  make verify-products       Build every library product declared by Package.swift"
	@echo "  make verify-examples       Build and run the PositronicKitExamples executable"
	@echo "  make verify-pktestsupport  Build PKTestSupport and an ordinary-import consumer in release mode"
	@echo "  make verify-public-consumers  Compile ordinary imports for every public library product"
	@echo "  make verify-public-api    Compare public Swift symbols with the reviewed Next / v5 baseline"
	@echo "  make update-public-api-baseline  Record an intentionally reviewed public API change"
	@echo "  make verify-release VERSION=x.y.z  Check local tag and release artifacts agree"
	@echo "  make verify-dependency-direction  Check the v4 target dependency boundaries"
	@echo "  make verify-v4-vocabulary  Check the v4 Timeline/Turn/Agent vocabulary"
	@echo "  make verify-documentation  Check docs catalog, navigation, links, pins, products, and vocabulary"
	@echo "  make verify-doc-snippets  Type-check every Swift fenced block under docs/"
	@echo "  make verify-agent-harness Run agent test-entrypoint regression tests"
	@echo "  make doctor                Report missing Swift and container runtime prerequisites"
	@echo "  make verify-gate-script-coverage  Check every gate script has a wired fixture test"
	@echo ""
	@echo "Linux (Podman or Docker):"
	@echo "  make linux-image           Build the pinned Linux development image"
	@echo "  make linux-build           Build in a Linux container (bind-mounted)"

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

test-fast:
	@set -eu; \
	 if [ -z "$(FAST_FILTER)" ]; then \
	   echo "make test-fast: generated test filter is empty; check the test taxonomy." >&2; \
	   exit 1; \
	 fi; \
	 echo "Running fast tests (--filter $(FAST_FILTER))..."; \
	 swift test $(SWIFT_BUILD_FLAGS) --filter "$(FAST_FILTER)"

validate-docs: verify-documentation
	@bash Scripts/validate-docs.sh

verify-documentation:
	@python3 Scripts/generate-doc-navigation.py --check
	@python3 Scripts/validate-documentation.py
	@python3 Scripts/validate-provider-capability-matrix.py
	@python3 Scripts/check-documentation-currency.py
	@bash Scripts/check-v4-vocabulary.sh
	@$(MAKE) verify-doc-snippets

# Type-check every ```swift block under docs/ against the real modules by
# building the generated DocSnippetConsumer target. Standalone entry point for
# the docs-snippet gate that `verify-documentation` also runs.
verify-doc-snippets:
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
	@python3 Scripts/check-workspace-tool-dispatch.py

# Preflight: report the Swift and container runtime prerequisites for the current platform.
doctor:
	@bash Scripts/doctor.sh "$(CONTAINER_RUNTIME)"

verify: verify-concurrency-scan verify-agent-harness verify-runtime-architecture verify-dependency-direction verify-test-layout verify-gate-script-coverage verify-story-coverage validate-docs verify-products verify-public-api verify-examples verify-pktestsupport verify-public-consumers test-fast test

verify-linux-coverage:
	@python3 -B Tests/Scripts/linux_coverage_report_test.py
	@bash Scripts/run-linux-coverage.sh

# The inner Linux gate used by both GitHub Actions and the outer containerized agent
# entrypoint. Native-linker discovery is exported once for every product,
# example, support, and test command so callers cannot accidentally omit it.
verify-linux-agent:
	@echo "Running agent/CI Linux verification contract..."
	@$(MAKE) verify-agent-harness verify-runtime-architecture verify-dependency-direction verify-test-layout verify-gate-script-coverage verify-story-coverage verify-documentation verify-products verify-public-api verify-examples verify-pktestsupport verify-public-consumers test-fast test

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

# Repeat the matching test cases `LINUX_TEST_REPETITIONS` times to reproduce flaky
# behavior. SwiftPM applies `--maximum-repetitions` per test case, unlike the nightly
# job's whole-suite iterations, so a concurrency-heavy suite can be stressed directly.
verify-linux-repeat:
	@if [ -z "$(LINUX_TEST_FILTER)" ]; then \
		echo "make: LINUX_TEST_FILTER is required." >&2; \
		exit 2; \
	fi
	@if [ -z "$(LINUX_TEST_REPETITIONS)" ]; then \
		echo "make: LINUX_TEST_REPETITIONS is required." >&2; \
		exit 2; \
	fi
	@if [ -n "$(LINUX_TEST_TRAITS)" ]; then \
		swift test $(SWIFT_BUILD_FLAGS) --scratch-path /scratch --jobs 1 --traits "$(LINUX_TEST_TRAITS)" --maximum-repetitions "$(LINUX_TEST_REPETITIONS)" --filter "$(LINUX_TEST_FILTER)"; \
	else \
		swift test $(SWIFT_BUILD_FLAGS) --scratch-path /scratch --jobs 1 --maximum-repetitions "$(LINUX_TEST_REPETITIONS)" --filter "$(LINUX_TEST_FILTER)"; \
	fi

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
	@echo "Running PositronicKitExamples..."
	@swift run --skip-build PositronicKitExamples

verify-pktestsupport:
	@echo "Building PKTestSupport in release configuration..."
	@swift build $(SWIFT_BUILD_FLAGS) -c release --target PKTestSupport
	@echo "Compiling an ordinary-import PKTestSupport consumer..."
	@swift build $(SWIFT_BUILD_FLAGS) -c release --product PKTestSupportConsumer
	@echo "Running the already-built ordinary-import PKTestSupport consumer..."
	@consumer_path="$$(swift build $(SWIFT_BUILD_FLAGS) -c release --show-bin-path)/PKTestSupportConsumer"; \
	if [ "$$(uname -s)" = "Darwin" ]; then \
		testing_framework_path="$$(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks"; \
		if [ ! -d "$$testing_framework_path/Testing.framework" ]; then \
			echo "Testing.framework not found at $$testing_framework_path" >&2; \
			exit 1; \
		fi; \
		DYLD_FRAMEWORK_PATH="$$testing_framework_path$${DYLD_FRAMEWORK_PATH:+:$$DYLD_FRAMEWORK_PATH}" \
			"$$consumer_path"; \
	else \
		"$$consumer_path"; \
	fi

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

verify-gate-script-coverage:
	@bash Scripts/check-gate-script-coverage.sh

verify-test-layout:
	@bash Scripts/check-test-layout.sh

verify-story-coverage:
	@python3 Scripts/check-story-coverage.py

verify-v4-vocabulary:
	@bash Scripts/check-v4-vocabulary.sh

# Nightly flake-detection report entrypoint (see .github/workflows/nightly-flake-detection.yml).
# Aggregates per-iteration xUnit files produced by repeated full-suite runs and reports
# every test that did not pass every run, by name with the failing iteration count.
# This target reports only; it never gates pull requests.
detect-flakes:
	@if [ -z "$(XUNIT_FILES)" ]; then \
		echo "make: XUNIT_FILES is required (for example: make detect-flakes XUNIT_FILES='.build/flake-detection/iteration-*.xml')." >&2; \
		exit 2; \
	fi
	@python3 Scripts/detect-flaky-tests.py --report $(XUNIT_FILES)

verify-agent-harness:
	@bash Tests/Scripts/doctor_test.sh
	@bash Tests/Scripts/run_linux_container_test.sh
	@bash Tests/Scripts/public_api_baseline_test.sh
	@bash Tests/Scripts/check_dependency_direction_test.sh
	@bash Tests/Scripts/check_test_layout_test.sh
	@bash Tests/Scripts/compile_doc_snippets_test.sh
	@bash Tests/Scripts/validate_docc_test.sh
	@bash Tests/Scripts/validate_docs_test.sh
	@bash Tests/Scripts/run_linux_coverage_test.sh
	@bash Tests/Scripts/list_library_products_test.sh
	@bash Tests/Scripts/test_fast_test.sh
	@python3 -B Tests/Scripts/provider_capability_matrix_test.py
	@python3 -B Tests/Scripts/linux_coverage_report_test.py
	@python3 -B Tests/Scripts/migrate_turn_execution_request_test.py
	@python3 -B Tests/Scripts/check_workspace_tool_dispatch_test.py
	@python3 -B Tests/Scripts/validate_documentation_test.py
	@python3 -B Tests/Scripts/check_documentation_currency_test.py
	@python3 -B Tests/Scripts/generate_doc_navigation_test.py
	@python3 -B Tests/Scripts/validate_release_readiness_test.py
	@python3 -B Tests/Scripts/check_v4_vocabulary_test.py
	@python3 -B Tests/Scripts/check_pr_docs_impact_test.py
	@python3 -B Tests/Scripts/check_story_coverage_test.py
	@python3 -B Tests/Scripts/detect_flaky_tests_test.py
	@python3 -B Tests/Scripts/generate_test_fast_filter_test.py
	@bash Tests/Scripts/check_gate_script_coverage_test.sh

# Linux testing intentionally has no native fallback. The shared runner
# performs the deeper access check and prints the sandbox-escalation
# remediation when a runtime is installed but unavailable.
require-container-runtime:
	@if [ -z "$(CONTAINER_RUNTIME)" ]; then \
		echo "make: PositronicKit Linux testing requires Podman or Docker." >&2; \
		echo "    Install Podman (preferred) or Docker, or set CONTAINER_RUNTIME=/absolute/path/to/runtime." >&2; \
		echo "    Run 'make doctor' for a full prerequisite check." >&2; \
		exit 1; \
	fi

# --- Linux container targets -------------------------------------------------
# Bind-mount the checkout so host edits are immediately visible in the container.
# Build artifacts land in the host .build/ directory (gitignored).

agent-verify: require-container-runtime
	@mkdir -p "$(AGENT_LOG_DIR)"
	@CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" LINUX_IMAGE="$(LINUX_IMAGE)" \
		LINUX_SWIFT_VERSION="$(LINUX_SWIFT_VERSION)" \
		bash Scripts/run-linux-container.sh \
		--log "$(AGENT_LOG_DIR)/verify.log" \
		--lock "$(AGENT_LOCK_FILE)" \
		-- make verify-linux-agent

agent-test: require-container-runtime
	@if [ -z "$(FILTER)" ]; then \
		echo "make: FILTER is required (for example: make agent-test FILTER='MessageContentTests')." >&2; \
		exit 2; \
	fi
	@mkdir -p "$(AGENT_LOG_DIR)" "$(LINUX_SCRATCH_DIR)"
	@CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" LINUX_IMAGE="$(LINUX_IMAGE)" \
		LINUX_SWIFT_VERSION="$(LINUX_SWIFT_VERSION)" \
		LINUX_TEST_FILTER="$(FILTER)" LINUX_TEST_TRAITS="$(TRAITS)" \
		bash Scripts/run-linux-container.sh \
		--log "$(AGENT_LOG_DIR)/test.log" \
		--lock "$(AGENT_LOCK_FILE)" \
		--scratch "$(LINUX_SCRATCH_DIR)" \
		-- make verify-linux-filter

# Repeat the filtered test cases N times to reproduce flaky concurrency behavior,
# e.g. `make agent-test-repeat FILTER='AgentAuthorityCoordinatorTests' N=20`.
agent-test-repeat: require-container-runtime
	@if [ -z "$(FILTER)" ]; then \
		echo "make: FILTER is required (for example: make agent-test-repeat FILTER='AgentAuthorityCoordinatorTests' N=20)." >&2; \
		exit 2; \
	fi
	@if [ -z "$(N)" ]; then \
		echo "make: N is required (per-test repetition count)." >&2; \
		exit 2; \
	fi
	@mkdir -p "$(AGENT_LOG_DIR)" "$(LINUX_SCRATCH_DIR)"
	@CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" LINUX_IMAGE="$(LINUX_IMAGE)" \
		LINUX_SWIFT_VERSION="$(LINUX_SWIFT_VERSION)" \
		LINUX_TEST_FILTER="$(FILTER)" LINUX_TEST_TRAITS="$(TRAITS)" \
		LINUX_TEST_REPETITIONS="$(N)" \
		bash Scripts/run-linux-container.sh \
		--log "$(AGENT_LOG_DIR)/test-repeat.log" \
		--lock "$(AGENT_LOCK_FILE)" \
		--scratch "$(LINUX_SCRATCH_DIR)" \
		-- make verify-linux-repeat

linux-image: require-container-runtime
	@CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" LINUX_IMAGE="$(LINUX_IMAGE)" \
		LINUX_SWIFT_VERSION="$(LINUX_SWIFT_VERSION)" \
		bash Scripts/run-linux-container.sh --build-only

linux-build: require-container-runtime
	@CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" LINUX_IMAGE="$(LINUX_IMAGE)" \
		LINUX_SWIFT_VERSION="$(LINUX_SWIFT_VERSION)" \
		bash Scripts/run-linux-container.sh --lock "$(AGENT_LOCK_FILE)" -- make build

linux-coverage: require-container-runtime
	@mkdir -p "$(LINUX_COVERAGE_SCRATCH_DIR)"
	@CONTAINER_RUNTIME="$(CONTAINER_RUNTIME)" LINUX_IMAGE="$(LINUX_IMAGE)" \
		LINUX_SWIFT_VERSION="$(LINUX_SWIFT_VERSION)" \
		bash Scripts/run-linux-container.sh \
		--lock "$(AGENT_LOCK_FILE)" \
		--scratch "$(LINUX_COVERAGE_SCRATCH_DIR)" \
		-- env LINUX_COVERAGE_SCRATCH_PATH=/scratch make verify-linux-coverage
