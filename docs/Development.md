# PositronicKit Development Guide

This guide covers contributor and agent setup. Application configuration belongs in
[Setup.md](Setup.md); release procedure belongs in [Releasing.md](Releasing.md).

## Platform gates

Use native Swift/Xcode on macOS. The canonical macOS gates are `make verify` and, when exercising
the optional Apple MiniLM trait, `make verify-macos-minilm`.

Linux verification runs only through the repository-owned Podman runner:

```bash
make doctor
make agent-verify
make agent-test FILTER='MessageContentTests'
make agent-test FILTER='MiniLMEmbeddingContractTests' TRAITS=MiniLMEmbeddings
```

The runner owns image selection, rootless identity, checkout mounts, linker paths, model paths,
logs, and shared-build locking. Host edits are visible in `/workspace`; build artifacts remain in
the gitignored `.build/` directory. If a sandbox blocks Podman, rerun the same Make target with
container-runtime permission rather than composing a different container command.

## Linux image and prerequisites

The development image supplies Swift 6.3.3, Rust stable, C/C++, `pkg-config`, OpenSSL headers,
`curl`, and `shasum` on Ubuntu 24.04. Build or refresh it with `make linux-image`; compile in it
with `make linux-build`.

The native MiniLM bridge additionally needs Rust, a C/C++ linker, `pkg-config`, OpenSSL headers,
and network access on first bootstrap. These are image prerequisites, not host installation steps.

SwiftPM’s `systemLibrary` integration supplies C flags but not the pkg-config library search path;
the Makefile therefore exports `PKFASTEMBED_PREFIX`, `PKG_CONFIG_PATH`, and `LIBRARY_PATH` for the
checksum-keyed bridge prefix. Do not bypass the shared runner when testing the bridge.

## MiniLM assets

`make build-minilm` and `make verify-minilm` bootstrap the pinned model assets and native bridge
idempotently. The model revision and per-file hashes live in
`native/pkfastembed/model-assets.sha256` and `Sources/PKLocalEmbeddings/MiniLMModelAssets.swift`.
The default cache and native prefix live under `.build`; override them with
`PKFASTEMBED_PREFIX` and `MINILM_MODEL_CACHE_ROOT` only when a separate cache is required.
`make verify-pin` rejects drift before bootstrap.

## Focused and sanitizer checks

Use `make agent-test FILTER='…'` for a focused Linux test. Use `make verify-linux-asan` for the
PKFastEmbed bridge only; it requires a nightly Rust toolchain with `rust-src` and defaults to the
`x86_64-unknown-linux-gnu` target. The full platform matrix is documented by `make help` and the
release guide; keep the Make targets as the single source of truth.

## Package boundaries and consumer stories

`PKContracts` is the leaf module for provider-neutral messages, model clients, tools, structured
output, embeddings, and diagnostics. Providers and embedding implementations depend on it without
importing `PositronicKit`; `PKUtilities` is package-internal and is not a public product. Run
`make verify-dependency-direction` to check these rules.

`Tests/PublicProductConsumer` is an ordinary-import compile story for every public library product.
The `verify-public-consumers` target builds it without `@testable` access, and the canonical
`verify`/`agent-verify` gates run it alongside the product builds.
