import PKShared
# Architecture Overview

Deep dive into the current PositronicKitCore runtime design.

## Modularity

PositronicKitCore keeps transport-neutral runtime orchestration in `PositronicKit`, shared contracts in `PKShared`, and prompt composition/rendering in `PKPrompt`.

## Dependency Injection

The runtime uses `swift-dependencies` internally so its orchestration services can collaborate without leaking dependency container setup into downstream applications.

### Example Usage

```swift
let chat = PositronicKitCore(llmService: myLLM)
```

## Data Flow

1. **User Query**: Received via `ChatEngine`.
2. **Context Gathering**: `ContextManager` retrieves relevant memories and filesystem notes.
3. **Prompt Construction**: `PKPrompt` DSL builds a provider-specific prompt.
4. **Execution**: `LLMService` communicates with the AI provider.
5. **Tool Routing**: If the AI calls a tool, `ToolRouter` executes runtime-managed tools and defers attached tools for host-side execution when needed.
