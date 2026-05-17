# PositronicKit

PositronicKit is a Swift toolkit for building AI agents. It gives you transport-neutral runtime orchestration, a structured prompt composition DSL, and the shared contracts to tie them together — without imposing a specific networking or hosting model.

## Package Layout

The package is organized into three core modules plus provider adapters:

- **PositronicKit** — the runtime layer: chat engine, orchestration stages, tool routing, timeline and workspace management, and provider-neutral LLM orchestration.
- **PKPrompt** — the prompt layer: a SwiftUI-style `@PromptBuilder` DSL, structured compression, cache-aware assembly, and prompt journaling for stable-prefix workflows.
- **PKShared** — the contract layer: API models, tool protocols, provider contracts, error types, structured logging, and shared utilities consumed by both modules above.

Provider targets ship separately so downstream users can opt in only to the concrete integrations they want:

- **PKOpenAIProvider** — OpenAI SDK adapter, OpenAI-specific message/tool conversion, embedding service, and convenience registration APIs.
- **PKOpenRouterProvider** — OpenRouter adapter and convenience registration APIs.
- **PKOllamaProvider** — Ollama adapter and convenience registration APIs.

Two additional targets ship with the package:

- **PositronicKitExamples** — runnable examples that double as living documentation.
- **PKTestSupport** — shared mocks, fixtures, and test helpers, available as a library product for downstream test targets.

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
import PKOpenAIProvider // optional concrete provider for OpenAI convenience APIs
```

If you want the convenience runtime initializers like `PositronicKitCore(openAIKey:)` or `PositronicKitCore(ollamaModel:)`, import the matching provider target. Those initializers do not live in the core `PositronicKit` module.

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

Use **PKOpenAIProvider**, **PKOpenRouterProvider**, or **PKOllamaProvider** when you want a concrete provider implementation without putting that SDK dependency into the core runtime target.

## Choose Your Entry Point

If you are starting fresh, pick the smallest surface that matches your need:

- **Use `PKPrompt` only** when you just need prompt composition, rendering, journaling, or token-budget-aware prompt assembly without timelines, tools, or runtime orchestration.
- **Use `PositronicKitCore`** when you want the transport-neutral runtime facade: chat turns, timelines, prompt assembly, tool routing, persistence hooks, and streamed `ChatEvent` handling.
- **Use provider packages** (`PKOpenAIProvider`, `PKOpenRouterProvider`, `PKOllamaProvider`) when you want convenience initializers or concrete provider registration without embedding those adapters into your own runtime layer.
- **Use custom workspaces** when your host app owns filesystem, remote execution, or attachment behavior. Implement `WorkspaceCreating` / `WorkspaceProtocol`, then inject that boundary into the runtime instead of forking core orchestration.
- **Use structured output APIs** when your main need is schema-driven responses and typed decoding on top of the shared provider contracts, whether or not you adopt the full runtime facade.

Common adoption paths:

- **Prompt experimentation / prompt tooling** → start with `PKPrompt`.
- **Single-process app or CLI agent runtime** → start with `PositronicKitCore`.
- **Runtime + OpenAI/OpenRouter/Ollama convenience setup** → add the matching provider package.
- **Host-owned execution environment** → start with `PositronicKitCore` plus your own workspace implementation.
- **Typed JSON / schema-first integrations** → use `PKShared` structured output types, optionally with the runtime later.

## Runtime: PositronicKit

PositronicKit is the orchestration layer. It manages the full lifecycle of an agent interaction — from resolving state, through prompt assembly and tool execution, to persisting results.

### Core Concepts

- **Timeline** — a unit of conversation and execution state.
- **AgentInstance** — reusable agent identity and configuration.
- **ChatEngine** — drives the chat loop: gather context → assemble prompt → stream LLM response → extract tool calls → persist results.
- **ToolRouter** — resolves and executes tools within timeline and workspace scope.
- **TimelineManager** — manages timeline lifecycle, archiving, and tool state.
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

The following public API surfaces are classified as **stable v1 extension points**. They are safe to depend on and will not change without a major version bump.

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
| **Pipeline** | `PipelineStage`, `PipelineBuilder`, `PipelineError` | PKShared | Custom pipeline stages (advanced) |

**Explicitly demoted to internal** (not part of v1 contract):
- `ChatEngine`, `ChatTurnContext`, `TurnOutputs`, `StreamedToolCall` — chat-runtime internals
- `PromptAssemblyContext`, `PromptAssemblyStage`, `PromptAssemblyOptions` — prompt pipeline internals
- `ContextManager`, `ContextPipelineContext`, `ContextGatheringEvent` — context pipeline internals
- `ToolRouter`, `ParsedToolCall`, `ToolExecutionOutcome` — tool routing internals
- All `InMemory*` stores — test support infrastructure

### Default Runtime Tool Policy

The v1 runtime ships with a fixed default tool policy through `TimelineManager`:

- filesystem tools are installed by default for timeline-managed sessions
- timeline observation tools (`timeline_list`, `timeline_peek`) are installed by default
- `timeline_send` is installed only when the timeline has an attached agent identity

This is currently an explicit runtime default, not a host-configurable policy surface.

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

let core = PositronicKitCore(openAIKey: "sk-...")
```

Or, if you want to stay provider-neutral in the core runtime surface, register a provider explicitly and construct `LLMService` from configuration:

```swift
import PositronicKit
import PKOpenAIProvider

PKOpenAIProvider.register()

let core = PositronicKitCore(
    llmService: LLMService(configuration: .init(
        apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "",
        provider: .openAI
    ))
)
```

### Prompt Assembly Diagnostics

Runtime prompt assembly uses PKPrompt underneath, but the runtime surface exposes a small control point through `PromptAssemblyOptions`.

- `overridePipeline` swaps the default assembly stages.
- `tokenBudget`, `compressor`, `structuredDiff`, and `structuredExecutor` control compression.
- `logger` enables `swift-log` diagnostics for stage execution, section resolution, and token-budget decisions.

## Prompt Composition: PKPrompt

PKPrompt lets you author prompts as structured trees, assemble them into validated sections, render them, and optionally journal changes across snapshots. You choose the layer of control you need.

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

print(await prompt.render() ?? "")
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
- Prompt assembly diagnostics are opt-in: pass a `Logger` in `PromptAssemblyOptions` and use log levels to control verbosity.

```swift
import Logging
import PositronicKit

let logger = Logger(label: "com.example.prompt-assembly")

let rendered = try await PromptAssembler.assemble(
    request,
    options: PromptAssemblyOptions(logger: logger)
)
```

For package-defined errors, PositronicKit uses `ErrorKit` through `PKShared.PKError`.

- Package error types conform to `PKError`.
- Stable `PKErrorDomain` and `errorCode` values identify failures.
- `userFriendlyMessage` is the preferred surfaced message.
- When propagating nested failures, prefer `ErrorKit.userFriendlyMessage(for:)` over raw `localizedDescription`.
