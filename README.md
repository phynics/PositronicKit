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

## Choosing An Entry Point

Pick the smallest surface that matches your need:

| Need | Start with |
|------|-----------|
| Prompt composition, rendering, journaling — no runtime | `PKPrompt` |
| Single-process app or CLI agent runtime | The `PositronicKit` facade |
| Runtime + OpenAI/OpenRouter/Ollama/Anthropic convenience setup | Add the matching provider package |
| On-device Apple Intelligence models (no key, no network) | Add `PKFoundationModelsProvider` — `PositronicKit(foundationModelsTools:)`; requires macOS 26+/Apple Silicon with Apple Intelligence enabled, surfaces unavailability as a typed `PKError` |
| Local embedding service | Add `PKLocalEmbeddings` |
| Host-owned filesystem/execution/attachment behavior | `PositronicKit` + your own `WorkspaceCreating` / `WorkspaceProtocol` |
| Typed JSON / schema-first integrations | `PKShared` structured output types, optionally with the runtime later |

## Runtime: PositronicKit

PositronicKit is the orchestration layer. It manages the full lifecycle of an agent interaction — from resolving state, through prompt assembly and tool execution, to persisting results.

### Two Ways In: Facade (Primary) vs. Direct Seams (Advanced)

- **The `PositronicKit` facade is the primary entry point.** Construct it, call `run(...)`, and consume the streamed `ChatEvent`s. It wires the runtime internally; most consumers never touch the underlying coordinators.
- **Advanced hosts may compose the public runtime seams directly.** When you own a server or a custom composition root, construct and hold `TimelineManager`, `ToolRouter`, and the persistence/workspace protocols yourself, or inject them into the facade via the grouped `runtime:` / `persistence:` initializers. This is a supported tier — not a private API — but you opt into more wiring in exchange for more control.

Prefer the facade unless you specifically need a seam it doesn't surface. The chat-loop internals (`ChatEngine`, the turn pipeline, prompt-assembly internals) remain implementation details either way.

### Core Concepts

- **Timeline** — a unit of conversation and execution state.
- **AgentInstance** — reusable agent identity and configuration.
- **`PositronicKit` facade** — `run(...)` drives the chat loop end to end: gather context → assemble prompt → stream LLM response → extract tool calls → persist results.
- **ToolRouter** — resolves and executes tools within timeline and workspace scope (advanced seam; the facade builds one for you).
- **TimelineManager** — manages timeline lifecycle, archiving, and tool state (advanced seam).
- **WorkspaceManager** — resolves concrete workspace implementations behind `WorkspaceProtocol`.

### Extension Points

PositronicKit is deliberately transport-neutral: no networking, RPC, multi-process hosting, or bundled provider SDKs in the core target. The key boundaries are:

- **Persistence protocols** for timelines, messages, workspaces, tools, agents, and request origins.
- **`WorkspaceCreating` and `WorkspaceProtocol`** for downstream-owned workspace resolution and execution behavior. `AgentWorkspaceService` is the bundled local provisioning implementation, not a required universal workspace model.
- **`PromptSectionProviding`** and **`ChatTurnPlugin`** for app-specific orchestration and context hooks.
- **Provider contracts in `PKShared`** for downstream-owned LLM adapters and tool/message projections.

#### v1 Extension Point Registry

These public API surfaces are the **v1 compatibility contract**: they only change across a major version. Anything not listed here (or explicitly called out as internal) may change between minor releases.

| Category | Protocol / Type | Module | Purpose |
|----------|----------------|--------|---------|
| **Tool contracts** | `Tool`, `AnyTool`, `ToolResult`, `ToolParameters`, `ToolError` | PKShared | Define and execute tools |
| **Orchestration hooks** | `ChatTurnPlugin`, `CompletedTurn` | PositronicKit | Post-turn processing |
| **Prompt customization** | `PromptSectionProviding`, `PromptBuildContext` | PositronicKit | Inject custom prompt sections |
| **Persistence** | `MessageStoreProtocol`, `TimelinePersistenceProtocol`, `WorkspacePersistenceProtocol`, `MemoryStoreProtocol`, `ToolPersistenceProtocol`, `AgentInstanceStoreProtocol`, `AgentTemplateStoreProtocol`, `RequestOriginStoreProtocol` | PositronicKit | Custom storage backends |
| **Key-value store** | `KeyValueStoreProtocol` | PositronicKit | Generic key-value persistence |
| **Vector search** | `VectorStoreProtocol`, `VectorStoreError` | PositronicKit | Custom vector search backends |
| **Health check** | `HealthCheckable` | PositronicKit | Service health reporting |
| **LLM providers** | `LLMServiceProtocol`, `LLMChatRequest`, `LLMStreamResult`, `LLMStreamChunk`, etc. | PKShared | Provider adapter contracts |
| **Provider registration** | `PKOpenAIProvider.register()`, `PKOpenRouterProvider.register()`, `PKOllamaProvider.register()`, `PKAnthropicProvider.register()` | Provider modules | Provider factory registration |
| **Workspace** | `WorkspaceProtocol`, `WorkspaceCreating`, `ToolReference`, `WorkspaceToolDefinition`, `WorkspaceToolError` | PositronicKit / PKShared | Custom workspace backends |
| **Configuration** | `LLMConfiguration`, `GenerationParameters`, `LLMProvider` | PKShared | LLM configuration |
| **Events** | `ChatEvent`, `ToolExecutionStatus`, `Message` | PKShared | Stream event types |
| **Sidecar directives** | `SidecarDirective`, `SidecarDelta`, `SidecarResult` (PKShared), `SidecarError` (PositronicKit) | PKShared / PositronicKit | Piggy-backed auxiliary generations riding a turn's response — see [Sidecar Directives](docs/SidecarDirectives.md) |
| **Pipeline** | `PipelineStage`, `PipelineBuilder`, `PipelineError` | PKShared | Custom pipeline stages (advanced) |
| **Runtime coordinators (advanced)** | `TimelineManager`, `ToolRouter`, `ToolExecutionOutcome`, `RuntimeToolPolicy` | PositronicKit | Direct runtime seams for hosts with their own composition root |

`InMemory*` stores (and `PositronicKit.PersistenceConfiguration.inMemory()`) are **public prototyping/test helpers**, not extension points — convenient for prototypes and tests, but not a stability contract.

**Internal** (not part of the v1 contract): `ChatEngine`, `ChatTurnContext`, `TurnOutputs`, `StreamedToolCall` (chat-runtime internals); `PromptAssembler`, `PromptAssemblyContext`, `PromptAssemblyStage`, `PromptAssemblyOptions` (prompt pipeline internals); `ContextManager`, `ContextPipelineContext`, `ContextGatheringEvent` (context pipeline internals); `ParsedToolCall`, `ToolHandlingResult`, `ToolTurnResult` (tool-routing internals).

### Default Runtime Tool Policy

`TimelineManager` applies a configurable default tool policy:

- filesystem tools are installed by default for timeline-managed sessions
- timeline observation tools (`timeline_list`, `timeline_peek`) are installed by default
- `timeline_send` is installed only when the timeline has an attached agent identity

Use `RuntimeToolPolicy` to disable any category or start with no runtime tools.

### Provider Registration

Concrete providers register factories against the shared provider registry. Import the provider module you want and register it before constructing an `LLMService` from configuration.

- Registration is required when you use `LLMService(configuration: ...)` directly.
- Repeated registration is safe; provider modules overwrite the same registry slot.
- The provider module owns registration for its provider family. In particular, `PKOpenAIProvider.register()` registers both `.openAI` and `.openAICompatible` factories.

```swift
import PositronicKit
import PKOpenAIProvider

PKOpenAIProvider.register()

let core = PositronicKit(
    llmService: LLMService(configuration: .init(
        apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "",
        provider: .openAI
    ))
)
```

Or use the provider target's convenience initializer:

```swift
import PKOpenAIProvider

let core = PositronicKit(openAIKey: "sk-...")
```

### Prompt Assembly Diagnostics

Runtime prompt assembly uses PKPrompt underneath. The assembly pipeline internals (`PromptAssembler`, `PromptAssemblyOptions`) are not public, but the diagnostics logger is: pass a `Logger` to `PositronicKit.run(..., promptAssemblyLogger:)` to surface stage execution, section resolution, and token-budget decisions for that turn.

```swift
import Logging
import PositronicKit

let logger = Logger(label: "com.example.prompt-assembly")
let events = try await chat.run(
    timelineId: timelineId,
    message: "Recommend the safest next step.",
    promptAssemblyLogger: logger
)
```

For full control over assembly (pipeline overrides, compression configuration) outside the runtime, compose at the `PKPrompt` layer directly (Layer 2/3 below).

## Prompt Composition: PKPrompt

PKPrompt lets you author prompts as structured trees, assemble them into validated sections, render them, and optionally journal changes across snapshots. You choose the layer of control you need.

> The three layer examples below are compile-checked in `Sources/PositronicKitExamples/PKPromptExamples.swift` (`renderLayer1ToString`, `assembleLayer2`, `journalLayer3`) and run via `swift run PositronicKitExamples`. Keep them in sync when editing these snippets.

### Layer 1: Prompt → String

The simplest path — compose a prompt tree and get canonical rendered text.

```swift
import PKPrompt

struct ToolingPrompt: Prompt {
    let tools: [String]

    var body: some Prompt {
        SystemPrompt("You are helping with project tooling.")

        TextPrompt(tools.map { "- \($0)" }.joined(separator: "\n"), id: "tools")
            .compression(.summarize)
            .cachePolicy(.semiStable)
    }
}

let prompt = AnyPrompt.build {
    ToolingPrompt(tools: ["build", "test", "lint"])
    UserPrompt("Recommend the safest next step.")
}

print(try await prompt.renderToString() ?? "")
```

If you don't need to inspect sections, manage compression outcomes, or track changes across snapshots, this is all you need.

### Layer 2: Prompt → AssembledPrompt → RenderedPrompt

When you need the full prompt structure — validated sections, rendered content, and compression outcomes.

```swift
import PKPrompt

let prompt = AnyPrompt.build {
    SystemPrompt("You are helping with project tooling.")
    TextPrompt("- build\n- test\n- lint", id: "tools")
        .compression(.summarize)
        .cachePolicy(.semiStable)
    UserPrompt("Recommend the safest next step.")
}

let assembled = try prompt.assemblePrompt()
let rendered = await assembled.render()

print(assembled.sections.map(\.id))
print(rendered.sections.map(\.id))
print(rendered.sectionsByID)
```

- `try prompt.assemblePrompt()` validates and orders sections into an `AssembledPrompt`.
- `await assembled.render()` produces the canonical `RenderedPrompt` — the single render artifact used for strings, snapshots, journaling, and provider projection.
- Each section carries both the requested `compression` strategy and the realized `compressionOutcome` after token-budget enforcement.

### Layer 3: RenderedPrompt → PromptJournal

When prompt structure needs to survive across snapshots — stable content stays materialized, semi-stable changes become overlays, and volatile content stays current-only.

```swift
import PKPrompt

var journal = PromptJournal()

let first = await (try! AnyPrompt.build {
    SystemPrompt("You are helping with project tooling.")
    TextPrompt("- build\n- test\n- lint", id: "tools")
        .cachePolicy(.semiStable)
    UserPrompt("Recommend the safest next step.")
}.assemblePrompt()).render()

let second = await (try! AnyPrompt.build {
    SystemPrompt("You are helping with project tooling.")
    TextPrompt("- build\n- test\n- lint\n- format", id: "tools")
        .cachePolicy(.semiStable)
    UserPrompt("Recommend the safest next step.")
}.assemblePrompt()).render()

let initialPlan = journal.observe(first)
let updatedPlan = journal.observe(second)
let compactedPlan = journal.compact()

print(initialPlan.baseSections.map(\.journalPath))
print(updatedPlan.overlaySections.map(\.journalPath))
print(compactedPlan?.overlaySections.isEmpty ?? false)
```

Cache policies drive the journaling behavior:

- **Stable** sections stay materialized in the committed base. If a stable section mutates, the journal produces a hard-reset plan rather than an overlay.
- **Semi-stable** sections become overlay entries when they change. Calling `compact()` folds outstanding overlays into the base.
- **Volatile** sections never enter the committed base; they are replaced wholesale on the next `observe()`.

`PromptJournal` is provider-neutral: it produces layered sections and journal paths, and a higher layer decides how to project overlays into provider-specific update messages.

### PromptBuilder Notes

`PromptBuilder` normalizes authored prompt syntax into structural `Prompt` values. `PromptAssembly` then lowers those values into `PromptNode` — the canonical internal IR.

- Use `AnyPrompt.build { ... }` for an explicit root container.
- Plain `for` loops use positional identity (`item_0`, `item_1`, ...).
- Use `ForEach(...)`, `PromptForEach(...)`, or `PromptBuilder.forEach(...)` when loop identity must come from domain data.
- Trait modifiers like `.priority(...)`, `.compression(...)`, and `.cachePolicy(...)` inherit through the subtree and are resolved once during assembly.

## Local Embeddings

`PKLocalEmbeddings` keeps the local embedding facade separate from the runtime core. The MiniLM backend is fully in-process: it has no provider or daemon fallback and accepts only host-provisioned model assets.

```swift
import PKLocalEmbeddings

// Apple default: Natural Language backend.
let appleDefault = LocalEmbeddingService()

// Linux: host-provisioned MiniLM assets in an explicit model directory.
let linux = LocalEmbeddingService(modelDirectory: URL(fileURLWithPath: "/path/to/model"))

// Apple MiniLM: opt in with the MiniLMEmbeddings trait.
let appleMiniLM = LocalEmbeddingService(miniLMModelDirectory: URL(fileURLWithPath: "/path/to/model"))
```

The Apple MiniLM path is built with the `MiniLMEmbeddings` trait (`swift test --traits MiniLMEmbeddings`); default Apple builds neither build nor link PKFastEmbed. Native setup is bootstrapped with `native/pkfastembed/bootstrap.sh --prefix <path>`, then discovered through `PKG_CONFIG_PATH`.

The pinned assets are `config.json`, `model.onnx`, `special_tokens_map.json`, `tokenizer.json`, `tokenizer_config.json`, and `vocab.txt` from `Qdrant/all-MiniLM-L6-v2-onnx` revision `5f1b8cd78bc4fb444dd171e59b18f3a3af89a079`. Exact checksums live in `native/pkfastembed/model-assets.sha256`; the host application owns fetching, verification, the model directory, and cache lifecycle.

Natural Language and MiniLM vectors are not interchangeable and must not share an index. When moving content across backends or platforms, rebuild embeddings on the destination platform.

## Logging And Errors

PositronicKit uses `swift-log` as its only logging API. Library code never calls `LoggingSystem.bootstrap(...)` — the downstream app, CLI, or test owns bootstrap and log-level selection:

```swift
import Logging
import PositronicKit
import PKOpenAIProvider

// Bootstrap once, early in your app/CLI/test startup.
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .debug   // raise to surface runtime + prompt-assembly diagnostics
    return handler
}

let core = PositronicKit(openAIKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "")
```

Long-lived runtime services log through `Logger.module(...)` in `PKShared`; prompt-assembly diagnostics are opt-in per turn via `promptAssemblyLogger` (see above).

For package-defined errors, PositronicKit uses `ErrorKit` through `PKShared.PKError`:

- Package error types conform to `PKError`, with stable `PKErrorDomain` and `errorCode` values.
- `userFriendlyMessage` is the preferred surfaced message; when propagating nested failures, prefer `ErrorKit.userFriendlyMessage(for:)` over raw `localizedDescription`.

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
