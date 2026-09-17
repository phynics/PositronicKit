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

`Package.swift` sets the consumer floor at Swift 6.2 (`swift-tools-version: 6.2`). Linux CI
qualifies Swift 6.3.3 (current) and Swift 6.4.0 (next) by running the same `make verify-linux-agent`
contract in each lane. The environments differ: `linux-current` uses the runner image's 6.3.3
toolchain, while `linux-next` installs `swift-6.4.0-RELEASE` from swift.org. The native macOS gate
runs whatever Xcode `macos-latest` ships, so it is floor-only. `make doctor` reports the resolved
toolchain and the Linux CI ceiling.

## Linux image and prerequisites

The development image supplies Swift and Python 3 for the documentation catalog gates on Ubuntu
24.04. The default base image is `swift:6.3.3-noble`; `LINUX_SWIFT_VERSION` selects another
toolchain:

```bash
make linux-image LINUX_SWIFT_VERSION=6.4.0   # Build the Swift 6.4.0 variant image
make agent-verify LINUX_SWIFT_VERSION=6.4.0  # Run the full gate in the Swift 6.4.0 image
```

The version selects the `swift:<version>-noble` base image and, unless `LINUX_IMAGE` is set,
derives the `positronickit-linux-dev-<version>` image tag. The Swift 6.4.0 base image depends on
`swift:6.4.0-noble`, which is not yet published to Docker Hub, so the local 6.4.0 container variant
does not build until that tag exists; use the `linux-next` CI lane to exercise Swift 6.4.0 in the
meantime. Build or refresh the default image with `make linux-image`. Compile in it with
`make linux-build`.

`agent-test` and `linux-coverage` give each toolchain its own SwiftPM scratch directory
(`.build/agent-scratch/swift-<version>` and `.build/linux-coverage-scratch/swift-<version>`), so
focused runs and coverage never mix compilers. `agent-verify` and `linux-build` use the
bind-mounted checkout `.build`; remove that directory before switching `LINUX_SWIFT_VERSION`, or
stale `.swiftmodule` files will fail or force a rebuild.

The `api/` public-symbol baselines are keyed by release, platform, and compiler major.minor.
`make verify-public-api` prefers the reviewed toolchain-scoped file
(`<release>-public-api-<platform>-swift-<X.Y>.json`) and falls back to the primary
`<release>-public-api-<platform>.json` when no scoped file exists. Swift 6.4 emits
extension-member relationships that 6.3 does not (and reports its graph output under `.build/out`),
so the 5.1 Linux surface carries both a primary and a scoped 6.4 baseline.
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
Provider targets, `PKTestSupport`, executables, and test targets are excluded.

This milestone reports Linux coverage only. It does not set floors, compare changed lines,
commit a baseline, or enforce macOS parity. A follow-up issue owns those decisions.

## Target boundaries

`PKContracts` owns runtime-neutral provider, tool, structured-output, and diagnostic
contracts. Providers depend on it without importing `PositronicKit`. Runtime dependencies stay
inward: `PKContracts` imports no project target. `make verify-dependency-direction` enforces this
boundary.
