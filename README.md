# PositronicKit

PositronicKit is an agent-building toolkit for Swift. It packages transport-neutral runtime orchestration, prompt composition, and shared contracts into `PositronicKit`, `PKPrompt`, and `PKShared`.

## Package Products

- `PositronicKit`: Core runtime orchestration and chat lifecycle
- `PKPrompt`: Prompt and context composition pipeline
- `PKShared`: Shared models, tool contracts, and utilities
- `PKTestSupport`: Test doubles, fixtures, and helpers

## Integration

Use PositronicKit as a Swift Package dependency:

```swift
.package(url: "https://github.com/your-org/PositronicKit.git", branch: "main")
```

Then import the modules you need:

```swift
import PositronicKit
import PKPrompt
import PKShared
```

## PositronicKit

`PositronicKit` is the runtime/orchestration layer. Its core concepts are:

- `Timeline`: a unit of conversation and execution state
- `WorkspaceReference` and `WorkspaceProtocol`: the execution/data environments available to a timeline
- `AgentInstance`: reusable agent identity and configuration
- `ToolRouter`, `TimelineManager`, and `ChatEngine`: the orchestration surfaces that tie prompts, tools, and persistence together

Condensed design intent:

- `PositronicKit` is transport-neutral
- networking and multi-process hosting models belong downstream of this package
- the core should expose extension points, not bundled transport implementations
- downstream systems should provide concrete workspace implementations behind `WorkspaceProtocol` and `WorkspaceCreating`
- prompt construction remains a `PKPrompt` concern; `PositronicKit` consumes assembled/rendered prompt artifacts

### Architecture

Typical `PositronicKit` flow:

1. Resolve timeline, agent, and workspace state through injected stores and managers.
2. Gather context and prompt sections through orchestration stages and providers.
3. Assemble prompts via `PKPrompt`.
4. Route tool calls through timeline/workspace-aware tool infrastructure.
5. Persist messages, timeline state, and related artifacts through injected persistence protocols.

### Extension Boundaries

Use these seams when integrating a downstream hosting model:

- persistence protocols for timelines, messages, workspaces, tools, agents, and request origins
- `WorkspaceCreating` and `WorkspaceManager` for resolving concrete workspace implementations
- `WorkspaceProtocol` and `WorkspaceCreating` for downstream-owned workspace resolution and execution behavior
- `PromptSectionProviding` and chat/context pipeline hooks for app-specific orchestration

This means `PositronicKit` can support downstream networking or multi-process hosting models without treating them as core runtime assumptions.

## PKPrompt

`PKPrompt` builds prompts as structured prompt trees and exposes one canonical render pass for downstream consumers.

Condensed design intent:

- authored prompts are `Prompt` values, usually built with `AnyPrompt.build { ... }`
- `PromptBuilder` lowers directly into `PromptNode`, the internal prompt IR
- `AssembledPrompt.Section` is the validated concrete section artifact
- `AssembledPrompt.RenderedPrompt` is the canonical rendered product for strings, snapshots, journaling, and provider projections
- requested compression strategy and realized compression outcome are both preserved
- prompt journaling is a `PKPrompt` concern via `PromptJournal`, not an ad-hoc diffing layer

### Architecture

Typical flow:

1. Author a prompt tree with reusable `Prompt` composites and primitive leaves.
2. Lower that tree into `PromptNode` through `PromptBuilder`.
3. Resolve and validate concrete sections with `try prompt.assemblePrompt()`.
4. Render once with `await assembled.render()`.
5. Feed the rendered prompt into `PromptJournal` when stable-prefix and overlay semantics matter.

The layers are:

- `Prompt -> String`
- `Prompt -> AssembledPrompt`
- `AssembledPrompt -> RenderedPrompt`
- `RenderedPrompt -> PromptJournal`

### Layer 1: Prompt -> String

Use this when you want the simplest path from prompt composition to canonical rendered text.

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

This path is the smallest surface: author a prompt and ask for canonical plain text.

### Layer 2: Prompt -> AssembledPrompt and RenderedPrompt

Use this when the prompt itself is the product and you need validated section structure, rendered sections, or canonical section text.

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

This layer exposes the full prompt structure:

- `try prompt.assemblePrompt()` returns validated, ordered `AssembledPrompt.Section` values
- `await assembled.render()` returns the canonical rendered product used for strings, snapshots, journaling, and provider conversion
- `compression` is the requested strategy; `compressionOutcome` and `compressionReport` describe what actually happened under token pressure

### Layer 3: RenderedPrompt -> PromptJournal

Use this when prompt structure needs to survive across snapshots so stable content can remain materialized, semi-stable changes can be overlaid, and volatile content can stay current-only.

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

This layer is what enables prompt journaling:

- stable sections stay materialized in the committed base
- semi-stable changes become overlay sections until `compact()`
- volatile sections never enter the committed base
- stable changes produce a hard-reset plan instead of an overlay

`PromptJournal` is intentionally provider-neutral. It produces layered prompt sections and journal paths; a higher layer can later decide how to project overlays into provider-specific update messages.

### PromptBuilder Notes

`PromptBuilder` now lowers directly into prompt nodes instead of creating intermediate block/conditional wrapper prompts.

- use `AnyPrompt.build { ... }` for an explicit root container
- plain `for` loops use positional identity (`item_0`, `item_1`, ...)
- use `ForEach(...)`, `PromptForEach(...)`, or `PromptBuilder.forEach(...)` when loop identity must come from domain data
- trait modifiers like `.priority(...)`, `.compression(...)`, and `.cachePolicy(...)` inherit through the subtree and are resolved once during assembly

Typical PKPrompt flow:

1. Compose a `Prompt` tree from primitive leaves and reusable composite prompts.
2. Use Layer 1 when you only need canonical plain-text prompt output.
3. Use Layer 2 when you need validated sections or the canonical rendered prompt artifact.
4. Use Layer 3 when prompt journaling, stable prefixes, and compaction behavior matter across snapshots.
