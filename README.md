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

`PKPrompt` now uses a body-based composition model inspired by SwiftUI:

- compose prompt sections with `body`
- use primitive leaves for actual rendered content
- use `AnyPrompt.build { ... }` for explicit top-level prompt composition
- use builder modifiers like `.priority(...)`, `.compression(...)`, and `.cachePolicy(...)` to inherit traits through composite sections
- resolve prompt trees into `ConcretePromptSection` values before budgeting, hashing, compression, or provider conversion
- assemble prompts with `assembledPrompt()` and render them through the canonical `rendered()` product

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

let sections = prompt.sections()
let assembled = try prompt.assembledPrompt()
let rendered = await assembled.rendered()

print(sections.map(\.id))
print(rendered.string)
print(rendered.sections.map(\.id))
```

`PromptBuilder` preserves concrete types for blocks, conditionals, loops, and optionals, while `AnyPrompt`
provides the explicit top-level root container.

Typical PKPrompt flow:

1. Compose a `Prompt` tree from primitive leaves and reusable composite sections.
2. Call `prompt.sections()` when you need concrete sections for inspection, budgeting, or hashing.
3. Call `try prompt.assembledPrompt()` when you need ordering validation.
4. Call `await assembled.rendered()` when you need canonical rendered output for plain text, snapshots, or provider message conversion.
