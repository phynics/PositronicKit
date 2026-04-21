# PositronicKit

PositronicKit encapsulates the core logic, context gathering, prompt pipelines, and cross-cutting components for advanced agent interactions. This includes `PositronicKit`, `PKPrompt`, and `PKShared`.

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

## PKPrompt

`PKPrompt` builds prompts as structured section graphs. You can consume the same prompt at three layers depending on how much structure and history you need.

### Layer 1: Prompt -> String

Use this when you want the simplest path from prompt composition to canonical rendered text.

```swift
import PKPrompt
import PKShared

struct ToolingSection: ContextSection {
    let tools: [String]

    private var toolSummary: String {
        tools.map { "- \($0)" }.joined(separator: "\n")
    }

    @ContextBuilder
    var body: some ContextSection {
        SystemPrompt("You are helping with project tooling.")

        ContextPrompt(toolSummary, id: "tools")
            .priority(.high)
            .compression(.summarize)
            .cachePolicy(.semiStable)
    }
}

let prompt = AnyPrompt.build {
    ToolingSection(tools: ["build", "test", "lint"])
    UserPrompt("Recommend the safest next step.")
}

let assembled = try prompt.assembledPrompt()
let rendered = await assembled.rendered()

print(rendered.string)
```

This path gives you ordering validation plus a single canonical plain-text prompt.

### Layer 2: Prompt -> Structured Prompt

Use this when the prompt itself is the product and you need access to concrete sections, rendered sections, or stable section snapshots.

```swift
import PKPrompt
import PKShared

let prompt = AnyPrompt.build {
    SystemPrompt("You are helping with project tooling.")
    ContextPrompt("- build\n- test\n- lint", id: "tools")
        .priority(.high)
        .compression(.summarize)
        .cachePolicy(.semiStable)
    UserPrompt("Recommend the safest next step.")
}

let sections = prompt.sections()
let assembled = try prompt.assembledPrompt()
let rendered = await assembled.rendered()

print(sections.map(\.id))
print(rendered.sections.map(\.id))
print(rendered.sectionsByID)
```

This layer exposes the full prompt structure:

- `prompt.sections()` returns `[ConcretePromptSection]`
- `try prompt.assembledPrompt()` validates ordering and prompt shape
- `await assembled.rendered()` returns the canonical rendered product used for strings, snapshots, and provider conversion

### Layer 3: Prompt -> Structured Prompt History

Use this when prompt structure needs to survive across turns so the runtime can detect stable prefixes, track what changed, and compact append-heavy histories later.

```swift
import PKPrompt
import PositronicKit
import PKShared

let prompt = AnyPrompt.build {
    SystemPrompt("You are helping with project tooling.")
    ContextPrompt("- build\n- test\n- lint", id: "tools")
        .cachePolicy(.semiStable)
    UserPrompt("Recommend the safest next step.")
}

let assembled = try prompt.assembledPrompt()

let history = TimelinePromptHistory()
let diff = await history.record(prompt: assembled)

await history.recordAppend(messageCount: 2, estimatedTokens: 400)

print(diff.stablePrefixCount)
print(diff.changedNodePaths)
print(await history.shouldCompact)
```

This layer is what enables prefix-caching-aware prompt evolution:

- rendered section snapshots are journaled by stable section identity and path
- prompt diffs report stable prefixes, changed nodes, added nodes, and removed nodes
- appended assistant/tool updates can be tracked separately from the base prompt snapshot
- compaction resets append pressure while preserving the journal base unless you explicitly clear it

That means the runtime can preserve cache-friendly prompt prefixes, represent turn-to-turn changes incrementally, and clean up the append chain later during compaction.

`PromptBuilder` preserves concrete types for blocks, conditionals, loops, and optionals, while `AnyPrompt`
provides the explicit top-level root container.

Typical PKPrompt flow:

1. Compose a `Prompt` tree from primitive leaves and reusable composite sections.
2. Use Layer 1 when you only need canonical plain-text prompt output.
3. Use Layer 2 when you need concrete or rendered section structure.
4. Use Layer 3 when prompt history, stable prefixes, and compaction behavior matter across turns.
