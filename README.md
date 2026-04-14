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
