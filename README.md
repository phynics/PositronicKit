# PositronicKit

PositronicKit is a Swift toolkit for building AI agents. It gives you transport-neutral runtime orchestration, a structured prompt composition DSL, and the shared contracts to tie them together — without imposing a specific networking or hosting model.

See [CHANGELOG.md](CHANGELOG.md) for release notes, migration notes, and tagged compatibility
history, and [docs/Releasing.md](docs/Releasing.md) for the release workflow.

## Quick Start

Add PositronicKit as a Swift Package dependency:

```swift
.package(url: "https://github.com/phynics/PositronicKit.git", from: "1.0.0")
```

Public products follow semver: patch releases preserve source compatibility, minor releases add functionality compatibly, and breaking API changes require a new major version.

Import the modules you need:

```swift
import PositronicKit    // runtime orchestration
import PKPrompt         // prompt composition
import PKShared         // shared contracts
import PKLocalEmbeddings // optional local embeddings facade
import PKOpenAIProvider  // optional concrete provider
```

Convenience runtime initializers like `PositronicKit(openAIKey:)` or `PositronicKit(ollamaModel:)` live in the matching provider target, not in the core `PositronicKit` module.

## Documentation

Detailed documentation has been split into focused guides:

- **[Setup Guide](docs/Setup.md)**: Configuration, logging, required services, and choosing your entry point.
- **[Usage Guide](docs/Usage.md)**: Managing agents, pipelines, and local embeddings.
- **[Architecture](docs/Architecture.md)**: Core concepts, state management, and the v1 extension point registry.
- **[Prompt Composition](docs/PKPromptComposition.md)**: Authoring models, caching, and prompt journaling.
- **[Sidecar Directives](docs/SidecarDirectives.md)**: Requesting auxiliary generations piggy-backed on the same LLM request.

## Package Layout

Core modules:

- **PositronicKit** — the runtime layer: chat engine, orchestration stages, tool routing, timeline and workspace management, and provider-neutral LLM orchestration.
- **PKPrompt** — the prompt layer: a SwiftUI-style `@PromptBuilder` DSL, structured compression, cache-aware assembly, and prompt journaling for stable-prefix workflows.
- **PKShared** — the contract layer: API models, tool protocols, provider contracts, error types, structured logging, and shared utilities.
- **PKLocalEmbeddings** — the platform-local embedding facade (`LocalEmbeddingService`). Apple uses Natural Language by default; Linux uses the host-provisioned MiniLM backend.

Provider targets ship separately so you opt in only to the integrations you want:

- **PKOpenAIProvider**, **PKOpenRouterProvider**, **PKOllamaProvider**, **PKAnthropicProvider**, **PKFoundationModelsProvider** — concrete adapters plus convenience registration APIs. `PKAnthropicProvider` speaks the Anthropic Messages API natively (event-based SSE, `input_schema` tools, top-level `system` param); structured output uses the forced synthetic-tool path since the API has no `response_format`.

Supporting targets:

- **PositronicKitExamples** — runnable examples that double as living documentation.
- **PKTestSupport** — shared mocks, fixtures, and test helpers for downstream test targets.

All products are supported on Apple platforms and Linux (see [Verification](#verification) for the gates that cover each).

## Verification

Build and test with standard SwiftPM commands (`swift build`, `swift test`, `swift run PositronicKitExamples`). Full verification runs through the root Makefile:

```bash
make verify            # Default build, docs, linkage audit, and tests (macOS)
make verify-linux      # Bootstrap pinned assets/native bridge and run the full Linux test suite
make verify-linux-asan # PKFastEmbed bridge tests under Linux x86_64 AddressSanitizer (bridge-only)
make verify-products   # Build every supported product on the current host
make verify-minilm     # Bootstrap pinned assets/native bridge and run MiniLM tests
```

`make verify-linux` needs a Rust toolchain, a C/C++ toolchain, `pkg-config`, OpenSSL development headers, `curl`, and `shasum` in addition to Swift — see [`AGENTS.md`](AGENTS.md#linux-development-setup) for details.

`make verify-minilm` downloads the pinned Hugging Face model assets on first use, validates their checksums, builds the Rust bridge, and stores the native prefix and model under `.build`. Override the locations with `PKFASTEMBED_PREFIX=...` and `PK_MINILM_MODEL_DIR=...`. `make verify-linux-asan` requires nightly Rust plus `rust-src` and scopes to `native/pkfastembed` only.

## Companion App

[`Yakamoz`](https://github.com/phynics/Yakamoz) is the native macOS showcase app for PositronicKit. It drives the runtime from a SwiftUI chat client and exposes the prompt pipeline, sent provider payloads, prompt journal, response metadata, tool traces, and local workspace state through an inspector drawer.
