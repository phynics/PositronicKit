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

    @PromptBuilder
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

`PKPrompt` itself stays transport-neutral and does not own a logging backend. When used through `PromptAssembler`, verbose diagnostics flow through `swift-log` by passing `PromptAssemblyOptions(logger:)` from the runtime layer.
