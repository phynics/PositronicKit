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

## Linux image and prerequisites

The development image supplies Swift 6.3.3 and Python 3 for the documentation catalog gates on
Ubuntu 24.04. Build or
refresh it with `make linux-image`. Compile in it with `make linux-build`.

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
