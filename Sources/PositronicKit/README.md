# PositronicKitCore

PositronicKitCore is the transport-neutral runtime facade for PositronicKit. It orchestrates chat turns, prompt assembly, tool routing, timelines, workspaces, and persistence without requiring downstream callers to interact with `swift-dependencies` directly.

## Documentation

- [Architecture Overview](docs/Architecture.md) - Deep dive into the engine's design, pipeline stages, and ReAct loop.
- [Setup & Configuration](docs/Setup.md) - How to configure LLM providers, database storage, and dependency injection.
- [Usage & Examples](docs/Usage.md) - Step-by-step guide to initializing agents and running chat streams.

## Logging

PositronicKitCore uses `swift-log` for runtime diagnostics.

- The library does not bootstrap logging globally.
- Hosts should call `LoggingSystem.bootstrap(...)` themselves when they want output.
- Prompt assembly diagnostics are enabled by passing `logger:` in `PromptAssemblyOptions`.

```swift
import Logging
import PositronicKit

let logger = Logger(label: "com.example.prompt")
let options = PromptAssemblyOptions(logger: logger)
```

## Key Components

### PositronicKitCore (Runtime Facade)
The public interface boundary for the runtime. It accepts required services as init parameters and injects them internally, so downstream applications use a normal Swift API instead of configuring `DependencyValues` around `ChatEngine`.

### AgentInstance
Represents a live, persistent agent entity. Each instance has its own private workspace (long-term memory) and private timeline (internal monologue).

### AgentInstanceManager
Handles the lifecycle of `AgentInstance` entities, including creation from templates, attachment to timelines, and workspace management.

## Getting Started

To get started with PositronicKitCore, refer to the [Usage Guide](docs/Usage.md).

```swift
import PositronicKit
import PKShared

// Minimal — all stores default to in-memory:
let chat = PositronicKitCore(llmService: myLLM)

// Production — grouped persistence:
let chat = PositronicKitCore(
    llmService: myLLM,
    persistence: .init(
        messageStore: myMessageStore,
        timelinePersistence: myTimelinePersistence,
        workspacePersistence: myWorkspacePersistence,
        memoryStore: myMemoryStore,
        toolPersistence: myToolPersistence,
        agentInstanceStore: myAgentInstanceStore,
        requestOriginStore: myRequestOriginStore,
        agentTemplateStore: myAgentTemplateStore
    ),
    embeddingService: myEmbeddingService,
    timelineManager: myTimelineManager
)

let stream = try await chat.run(
    timelineId: timelineId,
    message: "Hello!"
)

for try await event in stream {
    // Process chat events
}
```
