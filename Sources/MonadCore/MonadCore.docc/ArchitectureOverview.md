import MonadShared
# Architecture Overview

Deep dive into the MonadCore system design.

## Modularity

MonadCore follows a strict protocol-based architecture. Every major service is defined by a protocol, allowing for easy mocking during development and testing.

## Dependency Injection

We use the `swift-dependencies` library to manage shared state and service instances. This ensures that services like `PersistenceService` or `LLMService` can be swapped globally within a specific context.

### Example Usage

```swift
@Dependency(\.persistenceService) var persistence

func save() async throws {
    try await persistence.saveMemory(myMemory)
}
```

## Data Flow

1. **User Query**: Received via `ChatEngine`.
2. **Context Gathering**: `ContextManager` retrieves relevant memories and filesystem notes.
3. **Prompt Construction**: `MonadPrompt` DSL builds a provider-specific prompt.
4. **Execution**: `LLMService` communicates with the AI provider.
5. **Tool Routing**: If the AI calls a tool, `ToolRouter` dispatches the execution.
