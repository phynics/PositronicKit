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
- resolve prompt trees into semantic leaves before rendering, budgeting, hashing, or provider conversion

```swift
import PKPrompt

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

let prompt = Prompt {
    ToolingSection(tools: ["build", "test", "lint"])
    UserPrompt("Recommend the safest next step.")
}
```
