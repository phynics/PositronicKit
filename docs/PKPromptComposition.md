# PKPrompt Composition

`PKPrompt` uses a body-based composition model inspired by SwiftUI.

## Authoring Model

- Use composite `Prompt` types to group reusable prompt structure.
- Use primitive leaves like `TextPrompt` and `HistoryPrompt` when a type emits final prompt content directly.
- Use convenience wrappers like `SystemPrompt`, `ContextPrompt`, `UserPrompt`, and `HistoryPrompt` for common leaf roles.
- Use `AnyPrompt.build { ... }` as the explicit top-level prompt root.
- `Group` stays available when you want to introduce an explicit nested grouping boundary.

```swift
import PKPrompt

struct ToolingSection: Prompt {
    let tools: [String]

    private var toolSummary: String {
        tools.map { "- \($0)" }.joined(separator: "\n")
    }

    var body: some Prompt {
        SystemPrompt("You are helping with project tooling.")

        TextPrompt(toolSummary, id: "tools")
            .priority(.high)
            .compression(.summarize)
            .cachePolicy(.semiStable)
    }
}

let prompt = AnyPrompt.build {
    ToolingSection(tools: ["build", "test", "lint"])
    UserPrompt("Recommend the safest next step.")
}
```

## Modifier Inheritance

- Modifiers apply to the entire subtree beneath them.
- Child sections inherit `.priority(...)`, `.compression(...)`, and `.cachePolicy(...)` unless they set an explicit value closer to the leaf.
- This keeps composite sections small and avoids duplicating metadata on every leaf.

## Resolution Pipeline

Before prompt content is consumed by the runtime, composed sections are resolved into semantic leaves.

- rendering operates on resolved leaves
- token budgeting and compression operate on resolved leaves
- hash-tree generation and prompt-history diffs operate on resolved leaves
- provider message conversion uses `PromptSectionRole` on resolved leaves rather than stringly-typed section IDs

This separation keeps the builder API ergonomic while preserving stable prompt semantics for caching and compression.

## Runtime Integration

`PKPrompt` itself stays transport-neutral and does not own a logging backend. The runtime assembles prompts through its internal `PromptAssembler`; verbose assembly diagnostics flow through `swift-log` when you pass a `Logger` to `ThreadHandle.run(..., promptAssemblyLogger:)`.

## Journaling vs. Runtime Prompt History

There are two related but different concepts in the codebase:

- **`PromptJournal`** is the public prompt-layer API you should use when you want to observe prompt snapshots, reason about base/overlay/volatile sections, and decide when an accepted overlay should become the new baseline.
- **`ThreadPromptHistory`** is runtime-side bookkeeping used by `PositronicKit` to track prompt diffs, stable-prefix reuse, and append-pressure compaction across turns.

### When to use `PromptJournal`

Use `PromptJournal` when your application needs a prompt-facing abstraction, for example:

- visualizing prompt evolution over time
- deciding when a semistable overlay should be compacted into a new base
- tracking append pressure from accepted assistant/tool messages and auto-compacting the latest accepted prompt when the journal grows too stale
- working with prompt sections and journal layers directly outside the runtime loop

In that role, `PromptJournal` is the recommended public abstraction.

`PromptJournal` now has built-in append-pressure thresholds (`PromptJournalCompactionThresholds`).
After you accept a turn and append its assistant/tool messages to thread history, record
that pressure with `recordAppend(messages:)` (or `recordAppend(messageCount:estimatedTokens:)`).
When the thresholds are exceeded, the next `observe(_:)` auto-promotes the latest accepted prompt
into a new committed base before diffing again. This gives standalone prompt consumers the same
kind of safety valve that the runtime uses, without coupling them to runtime-only types.

### What `ThreadPromptHistory` is for

`ThreadPromptHistory` belongs to the runtime layer. It records rendered prompt snapshots and append pressure so the runtime can:

- estimate the stable prefix that can benefit downstream LLM caching
- track changed / added / removed prompt entries between turns
- compact append state when message-count or token thresholds are exceeded

If you are adopting `PositronicKit`, you usually do not need to instantiate or manage `ThreadPromptHistory` directly. It is runtime machinery, not the primary prompt-facing journaling surface.

The two systems intentionally overlap only partially:

- `PromptJournal` is authoritative for prompt-facing base / overlay / volatile layering and hard-reset semantics when stable prompt content changes.
- `ThreadPromptHistory` is authoritative for runtime cache-prefix accounting (`stablePrefixCount`) and append-pressure tracking inside the turn loop.
- For semistable prompt changes, their diff IDs are kept aligned and tested together, but they are not the same abstraction.

### Canonical recommendation

- For **prompt journaling use cases**, prefer `PromptJournal`.
- For **runtime diff/cache behavior**, let `PositronicKit` manage `ThreadPromptHistory` internally.
- If you need both, treat `PromptJournal` as the user-facing API and `ThreadPromptHistory` as runtime implementation support.

## Usage Examples (The Three Layers)

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

let initialPlan = try! journal.observe(first)
let updatedPlan = try! journal.observe(second)
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
