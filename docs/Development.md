# PositronicKit development

This guide covers contributor and agent setup. Application configuration belongs in
[Setup.md](Setup.md). Release procedure belongs in [Releasing.md](Releasing.md).

## Platform gates

Use native Swift/Xcode on macOS. The canonical macOS gate is `make verify`.

Linux verification runs only through the repository-owned container runner, which accepts Podman
(preferred) or Docker:

```bash
make doctor
make agent-verify
make agent-test FILTER='MessageContentTests'
make linux-coverage
```

The runner owns image selection, rootless identity, checkout mounts, logs, and shared-build locking.
Host edits are visible in `/workspace`. Build artifacts remain in
the gitignored `.build/` directory. If a sandbox blocks the container
runtime, rerun the same Make target with container-runtime permission rather than composing a
different container command.

Podman is preferred when both runtimes are installed. Set
`CONTAINER_RUNTIME=/absolute/path/to/runtime` to pin one explicitly; `make doctor` reports which
runtime resolved.

## Supported Swift toolchains

`Package.swift` sets the consumer floor at Swift 6.4 (`swift-tools-version: 6.4`). Linux CI runs
the `make verify-linux-agent` contract on Swift 6.4.0 installed from swift.org. The macOS CI lane
runs `make verify-macos-ci` on the `xcode-27` runner image, whose bundled Xcode 27 toolchain is
Swift 6.4 and whose Testing library declares `CustomTestReflectable`; the Xcode 26 SDK on
`macos-latest` ships Testing 6.3 without it. That lane runs only the Apple-platform gates; the
platform-neutral ones (lint, doc snippets, release-mode consumer builds) run on Linux, so the two
lanes together cover `make verify`, which remains the full local macOS gate. A preflight job runs
`make verify-static`, the gates that need no Swift toolchain, before either lane starts.
`make doctor` reports the required toolchain.

## Linux image and prerequisites

The development image supplies Swift 6.4.0 and Python 3 for the documentation catalog gates on
Ubuntu 24.04. Its base image is `swift:6.4.0-noble`:

```bash
make linux-image   # Build the Swift 6.4.0 image
make agent-verify  # Run the full gate in the Swift 6.4.0 image
```

The image uses the `swift:6.4.0-noble` base and the `positronickit-linux-dev-6.4.0` tag. Build or
refresh it with `make linux-image`. Compile in it with `make linux-build`.

The supported lane uses one Swift 6.4.0 build state; remove `.build` after changing build options
or dependencies so stale modules cannot survive a rebuild.

The `api/` public-symbol baselines are keyed by release and platform and are generated with the
supported Swift 6.4 toolchain. `make verify-public-api` compares against the primary
`<release>-public-api-<platform>.json` baseline.
`make update-public-api-baseline` records an intentional change for the running toolchain.

The supported toolchain is the version declared by `swift-tools-version` in `Package.swift`, which
`make doctor` reads. CI keeps one lane per platform at that version, and
[ADR 0011](adr/0011-swift-6-4-toolchain-floor.md) governs when the floor moves and why guarded
`#if compiler` fallbacks are not used.

## Focused checks

Use `make agent-test FILTER='…'` for a focused Linux test. The test layers,
tagging taxonomy, determinism rules, and the `make test-fast` inner loop are
defined in [Testing.md](Testing.md).

Provider conformance tests use the package-scoped `ScriptedProviderHTTPTransport` for Anthropic,
OpenRouter, Ollama, and runtime transport checks. OpenAI tests use `TestHTTPServer`. Foundation
Models tests use a scripted session. Run the provider suites with:

```bash
make agent-test FILTER='StreamDecodingConformanceTests|ProviderCancellationConformanceTests'
```

The executable provider capability matrix runs with:

```bash
make agent-test FILTER='ProviderCapabilityMatrixTests'
```

`make verify-documentation` validates documentation currency, the machine-readable matrix, its published table, malformed
input handling, and registration of every executable case.

These fixtures are internal to the package. Downstream tests should use public provider APIs or
`TestHTTPServer`, not the provider injection seams.

The shared fixture records requests and exposes an event-driven termination signal, so cancellation
tests do not depend on sleeps, polling, or live provider services.

## Linux coverage reports

Run `make linux-coverage` in the pinned Linux environment to execute the tests with
`--enable-code-coverage` and write the reports to `.build/linux-coverage/`.

The target writes the raw `llvm-cov` JSON, a normalized summary for `PositronicKit`,
`PKContracts`, `PKPrompt`, `PKUtilities`, and `PKObservable`, and a platform-asymmetry report.
Provider targets, `PKTestSupport`, executables, and test targets are excluded. Swift Build creates
one test runner per test target and exports each runner's coverage to the same file, so the target
re-exports the merged profile across every test product bundle in one `llvm-cov` invocation. Without
that merge, a module linked into a single test product, such as `PKObservable`, would be dropped.

This milestone reports Linux coverage only. It does not set floors, compare changed lines,
commit a baseline, or enforce macOS parity. A follow-up issue owns those decisions.

## Target boundaries

`PKContracts` owns runtime-neutral provider, tool, structured-output, and diagnostic
contracts. Providers depend on it without importing `PositronicKit`. Runtime dependencies stay
inward: `PKContracts` imports no project target. `make verify-dependency-direction` enforces this
boundary.
