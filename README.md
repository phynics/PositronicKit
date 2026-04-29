# PositronicKit

PositronicKit is a Swift toolkit for building AI agents. It gives you transport-neutral runtime orchestration, a structured prompt composition DSL, and the shared contracts to tie them together — without imposing a specific networking or hosting model.

The package is organized into three modules:

- **PositronicKit** — the runtime layer: chat engine, orchestration stages, tool routing, timeline and workspace management, and LLM service integration.
- **PKPrompt** — the prompt layer: a SwiftUI-style `@PromptBuilder` DSL, structured compression, cache-aware assembly, and prompt journaling for stable-prefix workflows.
- **PKShared** — the contract layer: API models, tool protocols, error types, structured logging, and shared utilities consumed by both modules above.

Two additional targets ship with the package:

- **PositronicKitExamples** — runnable examples that double as living documentation.
- **PKTestSupport** — shared mocks, fixtures, and test helpers, available as a library product for downstream test targets.

## Getting Started

Add PositronicKit as a Swift Package dependency:

```swift
.package(url: "https://github.com/your-org/PositronicKit.git", branch: "main")
```

Then import the modules you need:

```swift
import PositronicKit   // runtime orchestration
import PKPrompt        // prompt composition
import PKShared        // shared contracts
```

Build and run:

```
swift build                        # build all targets
swift test                         # run the full test suite
swift run PositronicKitExamples    # run the example harness
```

## Runtime: PositronicKit

PositronicKit is the orchestration layer. It manages the full lifecycle of an agent interaction — from resolving state, through prompt assembly and tool execution, to persisting results.

### Core Concepts

- **Timeline** — a unit of conversation and execution state.
- **AgentInstance** — reusable agent identity and configuration.
- **ChatEngine** — drives the chat loop: gather context → assemble prompt → stream LLM response → extract tool calls → persist results.
- **ToolRouter** — resolves and executes tools within timeline and workspace scope.
- **TimelineManager** — manages timeline lifecycle, archiving, and tool state.
- **WorkspaceManager** — resolves concrete workspace implementations behind `WorkspaceProtocol`.

### Design Intent

PositronicKit is deliberately transport-neutral. It does not bundle networking, RPC, or multi-process hosting — those concerns belong in downstream packages that plug into PositronicKit's extension points.

This means a downstream package can wire up its own persistence, networking, and UI layers without forking or patching PositronicKit itself. The key extension boundaries are:

- **Persistence protocols** for timelines, messages, workspaces, tools, agents, and request origins.
- **`WorkspaceCreating` and `WorkspaceProtocol`** for downstream-owned workspace resolution and execution behavior.
- **`PromptSectionProviding`** and **`ChatTurnPlugin`** for app-specific orchestration and context hooks.

### Typical Flow

1. Resolve timeline, agent, and workspace state through injected stores and managers.
2. Gather context and prompt sections through orchestration stages and providers.
3. Assemble prompts via PKPrompt.
4. Stream the LLM response and extract tool calls.
5. Route tool calls through timeline/workspace-aware tool infrastructure.
6. Persist messages, timeline state, and related artifacts through injected persistence protocols.

## Prompt Composition: PKPrompt

PKPrompt lets you author prompts as structured trees, assemble them into validated sections, render them, and optionally journal changes across snapshots. You choose the layer of control you need.

### Layer 1: Prompt → String

The simplest path — compose a prompt tree and get canonical rendered text.

```swift
import PKPrompt

struct ToolingPrompt: Prompt {
    let tools: [String]

    @PromptBuilder
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
