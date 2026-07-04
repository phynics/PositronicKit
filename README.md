# PositronicKit

PositronicKit is a Swift toolkit for building AI agents. It gives you transport-neutral runtime orchestration, a structured prompt composition DSL, and the shared contracts to tie them together — without imposing a specific networking or hosting model.

## Package Layout

The package is organized into three core modules plus provider adapters:

- **PositronicKit** — the runtime layer: chat engine, orchestration stages, tool routing, timeline and workspace management, and provider-neutral LLM orchestration.
- **PKPrompt** — the prompt layer: a SwiftUI-style `@PromptBuilder` DSL, structured compression, cache-aware assembly, and prompt journaling for stable-prefix workflows.
- **PKShared** — the contract layer: API models, tool protocols, provider contracts, error types, structured logging, and shared utilities consumed by both modules above.
- **PKLocalEmbeddings** — the platform-local embedding facade: import this when you want `LocalEmbeddingService`. Apple uses Natural Language by default; Linux support is temporarily blocked pending recorded native qualification on every supported architecture.

Provider targets ship separately so downstream users can opt in only to the concrete integrations they want:

- **PKOpenAIProvider** — OpenAI SDK adapter, OpenAI-specific message/tool conversion, embedding service, and convenience registration APIs.
- **PKOpenRouterProvider** — OpenRouter adapter and convenience registration APIs.
- **PKOllamaProvider** — Ollama adapter and convenience registration APIs.

Two additional targets ship with the package:

- **PositronicKitExamples** — runnable examples that double as living documentation.
- **PKTestSupport** — shared mocks, fixtures, and test helpers, available as a library product for downstream test targets.

## Support Matrix

| Product | Apple Platforms | Linux | Notes |
|---------|-----------------|-------|-------|
| `PositronicKit`, `PKPrompt`, `PKShared` | Supported | Supported | Core portable modules. |
| `PKLocalEmbeddings` | Supported | Temporarily blocked | The in-process MiniLM implementation is present, but Linux support is not advertised until the manual native verification gates pass on every supported architecture. |
| `PKOpenRouterProvider`, `PKOllamaProvider` | Supported | Portable candidate | Networking imports are Linux-safe. |
| `PKOpenAIProvider` | Supported | Portable candidate | Linux support depends on the pinned OpenAI SDK build. |
| `PKTestSupport`, `PositronicKitExamples` | Supported | Portable candidate | Verified through the package graph. |

## Quick Start

Add PositronicKit as a Swift Package dependency:

```swift
.package(url: "https://github.com/phynics/PositronicKit.git", branch: "main")
```

Then import the modules you need:

```swift
import PositronicKit   // runtime orchestration
import PKPrompt        // prompt composition
import PKShared        // shared contracts
import PKLocalEmbeddings // optional local embeddings facade
import PKOpenAIProvider // optional concrete provider for OpenAI convenience APIs
```

If you want the convenience runtime initializers like `PositronicKit(openAIKey:)` or `PositronicKit(ollamaModel:)`, import the matching provider target. Those initializers do not live in the core `PositronicKit` module.

If you use `LocalEmbeddingService`, import `PKLocalEmbeddings` alongside `PositronicKit`. On Apple, `LocalEmbeddingService()` uses Natural Language by default. The opt-in Apple MiniLM path is built with the `MiniLMEmbeddings` trait:

```bash
swift test --traits MiniLMEmbeddings
```

## Companion App

[`Yakamoz`](https://github.com/phynics/Yakamoz) is the native macOS showcase app for
PositronicKit. It drives the runtime from a SwiftUI chat client and exposes the prompt
pipeline, sent provider payloads, prompt journal, response metadata, tool traces, and local
workspace state through an inspector drawer.

## Manual verification

Verification is run explicitly through the root Makefile:

```bash
make verify           # Default build, docs, linkage audit, and tests (macOS)
make verify-linux     # Bootstrap pinned assets/native bridge and run the full Linux test suite
make verify-products  # Build every supported product on the current host
make verify-minilm    # Bootstrap pinned assets/native bridge and run MiniLM tests
```

`make verify-linux` needs a Rust toolchain, a C/C++ toolchain, `pkg-config`,
OpenSSL development headers, `curl`, and `shasum` in addition to Swift — see
[`AGENTS.md`](AGENTS.md#linux-development-setup) for the full list and why
each is required.

`make verify-minilm` downloads the pinned Hugging Face model assets on first
use, validates their checksums, builds the Rust bridge, and stores the native
prefix and model under `.build`. Override those locations when needed:

```bash
make verify-minilm \
  PKFASTEMBED_PREFIX=/path/to/prefix \
  PK_MINILM_MODEL_DIR=/path/to/model
```

Build and run:

```
swift build                        # build all targets
swift test                         # run the full test suite
swift run PositronicKitExamples    # run the example harness
```

## Choosing A Layer

Use **PositronicKit** when you want the runtime orchestration layer: timelines, context gathering, prompt assembly, tool routing, streaming, and persistence hooks.

Use **PKPrompt** when you want prompt composition without the runtime: authored prompt trees, validated sections, token-budget-aware assembly, rendering, and journaling.

Use **PKShared** when you need the shared contracts directly: API models, tool protocols, provider contracts, errors, logging helpers, and utilities.

Use **PKLocalEmbeddings** when you want the platform-local embedding service. It keeps the embedding facade separate from the runtime core.

Use **PKOpenAIProvider**, **PKOpenRouterProvider**, or **PKOllamaProvider** when you want a concrete provider implementation without putting that SDK dependency into the core runtime target.

## Choose Your Entry Point

If you are starting fresh, pick the smallest surface that matches your need:

- **Use `PKPrompt` only** when you just need prompt composition, rendering, journaling, or token-budget-aware prompt assembly without timelines, tools, or runtime orchestration.
- **Use the `PositronicKit` facade** (the primary entry point) when you want the transport-neutral runtime: chat turns, timelines, prompt assembly, tool routing, persistence hooks, and streamed `ChatEvent` handling. Advanced hosts can also compose the runtime seams (`TimelineManager`, `ToolRouter`, …) directly — see "Two Ways In" below.
- **Use provider packages** (`PKOpenAIProvider`, `PKOpenRouterProvider`, `PKOllamaProvider`) when you want convenience initializers or concrete provider registration without embedding those adapters into your own runtime layer.
- **Use custom workspaces** when your host app owns filesystem, remote execution, or attachment behavior. Implement `WorkspaceCreating` / `WorkspaceProtocol`, then inject that boundary into the runtime instead of forking core orchestration.
- **Use structured output APIs** when your main need is schema-driven responses and typed decoding on top of the shared provider contracts, whether or not you adopt the full runtime facade.

Common adoption paths:

- **Prompt experimentation / prompt tooling** → start with `PKPrompt`.
- **Single-process app or CLI agent runtime** → start with `PositronicKit`.
- **Runtime + OpenAI/OpenRouter/Ollama convenience setup** → add the matching provider package.
- **Local embedding service** → add `PKLocalEmbeddings` alongside `PositronicKit`.
- **Host-owned execution environment** → start with `PositronicKit` plus your own workspace implementation.
- **Typed JSON / schema-first integrations** → use `PKShared` structured output types, optionally with the runtime later.

## Local Embeddings

`PKLocalEmbeddings` keeps the local embedding facade separate from the runtime core. The MiniLM backend is fully in-process: it has no provider or daemon fallback and accepts only host-provisioned model assets. Native setup is bootstrapped with `native/pkfastembed/bootstrap.sh --prefix <path>`, then discovered through `PKG_CONFIG_PATH`.

The pinned assets are `Qdrant/all-MiniLM-L6-v2-onnx` revision `5f1b8cd78bc4fb444dd171e59b18f3a3af89a079`; exact checksums are in `native/pkfastembed/model-assets.sha256`. Applications own the model directory and cache lifecycle.

On Linux, construct `LocalEmbeddingService(modelDirectory:)`. On Apple builds using the `MiniLMEmbeddings` trait, construct `LocalEmbeddingService(miniLMModelDirectory:)`. Default Apple builds construct `LocalEmbeddingService()` and neither build nor link PKFastEmbed.

Natural Language and MiniLM vectors are not interchangeable and must not share an index. Re-embed source content whenever the backend or platform changes.

## Runtime: PositronicKit

PositronicKit is the orchestration layer. It manages the full lifecycle of an agent interaction — from resolving state, through prompt assembly and tool execution, to persisting results.

### Two Ways In: Facade (Primary) vs. Direct Seams (Advanced)

- **The `PositronicKit` facade is the primary entry point.** Construct it, call `run(...)`, and consume the streamed `ChatEvent`s. It wires the runtime internally, so most consumers never touch the underlying coordinators. Single-process apps and CLIs should start here.
- **Advanced hosts may compose the public runtime seams directly.** When you own a server or a custom composition root, you can construct and hold `TimelineManager`, `ToolRouter`, and the persistence/workspace protocols yourself, and even inject them back into the facade via the grouped `runtime:` / `persistence:` initializers. This is the supported "advanced" tier — not a private API — but you opt into more wiring in exchange for more control.

Prefer the facade unless you specifically need a seam it doesn't surface. The chat-loop internals (`ChatEngine`, the turn pipeline, prompt-assembly internals) remain runtime implementation details either way.

### Core Concepts

- **Timeline** — a unit of conversation and execution state.
- **AgentInstance** — reusable agent identity and configuration.
- **`PositronicKit` facade** — the primary entry point; `run(...)` drives the chat loop end to end (gather context → assemble prompt → stream LLM response → extract tool calls → persist results).
- **ToolRouter** — resolves and executes tools within timeline and workspace scope (advanced seam; the facade builds one for you).
- **TimelineManager** — manages timeline lifecycle, archiving, and tool state (advanced seam).
- **WorkspaceManager** — resolves concrete workspace implementations behind `WorkspaceProtocol`.

### Typical Flow

1. Resolve timeline, agent, and workspace state through injected stores and managers.
2. Gather context and prompt sections through orchestration stages and providers.
3. Assemble prompts via PKPrompt.
4. Stream the LLM response and extract tool calls.
5. Route tool calls through timeline/workspace-aware tool infrastructure.
6. Persist messages, timeline state, and related artifacts through injected persistence protocols.

### Extension Points

PositronicKit is deliberately transport-neutral. It does not bundle networking, RPC, or multi-process hosting, and it no longer embeds concrete provider SDK adapters in the core target. Those concerns belong in downstream packages or the optional provider targets.

The key boundaries are:

- **Persistence protocols** for timelines, messages, workspaces, tools, agents, and request origins.
- **`WorkspaceCreating` and `WorkspaceProtocol`** for downstream-owned workspace resolution and execution behavior.
- **`PromptSectionProviding`** and **`ChatTurnPlugin`** for app-specific orchestration and context hooks.
- **Provider contracts in `PKShared`** for downstream-owned LLM adapters and tool/message projections.

Workspace ownership is split intentionally:

- **Core runtime policy**: `TimelineManager` coordinates timeline lifecycle, context gathering, default tool installation, and workspace attachment.
- **Host-owned workspace behavior**: `WorkspaceProtocol` and `WorkspaceCreating` define how files, tools, and execution actually work for a concrete workspace backend.
- **Default local provisioning**: `AgentWorkspaceService` is the bundled local/runtime provisioning implementation, not a required universal workspace model.

#### v1 Extension Point Registry

The following public API surfaces are the **intended extension points** for downstream consumers.
PositronicKit is currently **pre-1.0**: these surfaces are the most stable parts of the API and we
make a best effort to avoid breaking them, but until a tagged 1.0 release they may change with a
minor version bump. After 1.0, these become the v1 compatibility contract and will only change
across a major version.

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
| **Provider registration** | `PKOpenAIProvider.register()`, `PKOpenRouterProvider.register()`, `PKOllamaProvider.register()` | Provider modules | Provider factory registration |
| **Workspace** | `WorkspaceProtocol`, `WorkspaceCreating`, `WorkspaceTool`, `WorkspaceToolError` | PositronicKit | Custom workspace backends |
| **Configuration** | `LLMConfiguration`, `GenerationParameters`, `LLMProvider` | PKShared | LLM configuration |
| **Events** | `ChatEvent`, `ToolExecutionStatus`, `Message` | PKShared | Stream event types |
| **Sidecar directives** | `SidecarDirective`, `SidecarDelta`, `SidecarResult` (PKShared), `SidecarError` (PositronicKit) | PKShared / PositronicKit | Piggy-backed auxiliary generations riding a turn's response — see [Sidecar Directives](docs/SidecarDirectives.md) |
| **Pipeline** | `PipelineStage`, `PipelineBuilder`, `PipelineError` | PKShared | Custom pipeline stages (advanced) |
| **Runtime coordinators (advanced)** | `TimelineManager`, `ToolRouter`, `ToolExecutionOutcome`, `RuntimeToolPolicy` | PositronicKit | Direct runtime seams for hosts with their own composition root; the facade builds these for you, or accepts them via the grouped `runtime:` initializer |

The **`PositronicKit` facade** is the primary public entry point (`run(...)`). The "advanced" seams
above are fully supported but optional — reach for them only when you own the composition root and
need direct access (see "Two Ways In" above).

`InMemory*` stores (and `PositronicKit.PersistenceConfiguration.inMemory()`) are **public prototyping/test
helpers**, not extension points — convenient for prototypes and tests, but not a stability contract.

**Explicitly demoted to internal** (not part of v1 contract):
- `ChatEngine`, `ChatTurnContext`, `TurnOutputs`, `StreamedToolCall` — chat-runtime internals
- `PromptAssembler`, `PromptAssemblyContext`, `PromptAssemblyStage`, `PromptAssemblyOptions` — prompt pipeline internals
- `ContextManager`, `ContextPipelineContext`, `ContextGatheringEvent` — context pipeline internals
- `ParsedToolCall`, `ToolHandlingResult`, `ToolTurnResult` — tool-routing internals (`package`-scoped)

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

let service = LLMService(configuration: .init(
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "",
    provider: .openAI
))
```

Provider targets also expose convenience APIs where appropriate, for example:

```swift
import PKOpenAIProvider

let core = PositronicKit(openAIKey: "sk-...")
```

Or, if you want to stay provider-neutral in the core runtime surface, register a provider explicitly and construct `LLMService` from configuration:

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

### Prompt Assembly Diagnostics

Runtime prompt assembly uses PKPrompt underneath. Internally, the runtime threads a
`PromptAssemblyOptions` value through the assembly pipeline to control:

- `overridePipeline` — swaps the default assembly stages.
- `tokenBudget`, `compressor`, `structuredDiff`, and `structuredExecutor` — control compression.
- `logger` — enables `swift-log` diagnostics for stage execution, section resolution, and token-budget decisions.

`PromptAssembler` and `PromptAssemblyOptions` are **internal** (see the demoted list above) and are
not reachable from downstream packages. The one diagnostic that *is* exposed publicly is the logger:
pass a `Logger` to `PositronicKit.run(..., promptAssemblyLogger:)` to surface stage execution, section
resolution, and token-budget decisions for that turn.

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

For full control over assembly (pipeline overrides, compression configuration) outside the runtime,
compose at the `PKPrompt` layer directly (Layer 2/3 below).

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

This is the smallest surface area: author a prompt, get plain text. If you don't need to inspect sections, manage compression outcomes, or track changes across snapshots, this is all you need.

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

At this layer you have full visibility into the prompt pipeline:

- `try prompt.assemblePrompt()` validates and orders sections into an `AssembledPrompt`.
- `await assembled.render()` produces the canonical `RenderedPrompt` — the single render artifact used for strings, snapshots, journaling, and provider projection.
- Each section carries both the requested `compression` strategy and the realized `compressionOutcome` after token-budget enforcement, so you can observe exactly what happened.

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

- **Stable** sections stay materialized in the committed base. If a stable section mutates, the journal produces a hard-reset plan rather than an overlay — the downstream consumer must decide how to handle the break.
- **Semi-stable** sections become overlay entries when they change. Calling `compact()` folds outstanding overlays into the base.
- **Volatile** sections never enter the committed base. They exist only in the current snapshot and are replaced wholesale on the next `observe()`.

`PromptJournal` is intentionally provider-neutral. It produces layered sections and journal paths; a higher layer decides how to project overlays into provider-specific update messages.

### PromptBuilder Notes

`PromptBuilder` normalizes authored prompt syntax into structural `Prompt` values. `PromptAssembly` then lowers those values into `PromptNode` — the canonical internal IR.

- Use `AnyPrompt.build { ... }` for an explicit root container.
- Plain `for` loops use positional identity (`item_0`, `item_1`, ...).
- Use `ForEach(...)`, `PromptForEach(...)`, or `PromptBuilder.forEach(...)` when loop identity must come from domain data.
- Trait modifiers like `.priority(...)`, `.compression(...)`, and `.cachePolicy(...)` inherit through the subtree and are resolved once during assembly.

## Logging And Errors

PositronicKit uses `swift-log` as its only logging API.

- Library code never calls `LoggingSystem.bootstrap(...)` for you.
- Downstream apps, CLIs, or tests own logging bootstrap and log-level selection.
- Long-lived runtime services log through `Logger.module(...)` in `PKShared`.
- Prompt-assembly diagnostics are opt-in per turn via `PositronicKit.run(..., promptAssemblyLogger:)` (see "Prompt Assembly Diagnostics" above). Control verbosity through the log level you select when bootstrapping.

The downstream app owns logging bootstrap and log-level selection:

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

For package-defined errors, PositronicKit uses `ErrorKit` through `PKShared.PKError`.

- Package error types conform to `PKError`.
- Stable `PKErrorDomain` and `errorCode` values identify failures.
- `userFriendlyMessage` is the preferred surfaced message.
- When propagating nested failures, prefer `ErrorKit.userFriendlyMessage(for:)` over raw `localizedDescription`.
