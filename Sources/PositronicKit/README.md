# PositronicKit

PositronicKit is the transport-neutral runtime facade for PositronicKit. It orchestrates chat turns, prompt assembly, tool routing, timelines, workspaces, and persistence through explicit initializer injection rather than a shared dependency container.

## Documentation

- [Architecture Overview](../../docs/Architecture.md) - Deep dive into the engine's design, pipeline stages, and ReAct loop.
- [Setup & Configuration](../../docs/Setup.md) - How to configure LLM providers, storage, and runtime wiring.
- [Usage & Examples](../../docs/Usage.md) - Step-by-step guide to initializing agents and running chat streams.
- [Sidecar Directives](../../docs/SidecarDirectives.md) - Piggy-backed auxiliary generations (title, summary, tone, etc.) riding the same request as a turn's response.

## Logging

PositronicKit uses `swift-log` for runtime diagnostics.

- The library does not bootstrap logging globally.
- Hosts should call `LoggingSystem.bootstrap(...)` themselves when they want output.
- Prompt-assembly diagnostics are enabled per turn by passing a `Logger` to
  `PositronicKit.run(..., promptAssemblyLogger:)`. The internal `PromptAssembler` /
  `PromptAssemblyOptions` types are not part of the public surface.

```swift
import Logging
import PositronicKit

let logger = Logger(label: "com.example.prompt")
let events = try await chat.run(
    timelineId: timelineId,
    message: "…",
    promptAssemblyLogger: logger
)
```

## Key Components

### PositronicKit (Runtime Facade)
The public interface boundary for the runtime. It accepts required services as init parameters and wires them internally, so downstream applications use a normal Swift API instead of configuring a shared dependency registry around `ChatEngine`.

### AgentInstance
Represents a live, persistent agent entity. Each instance has its own private workspace (long-term memory) and private timeline (internal monologue).

### AgentInstanceManager
Handles the lifecycle of `AgentInstance` entities, including creation from templates, attachment to timelines, and workspace management.

## Getting Started

To get started with PositronicKit, refer to the [Usage Guide](../../docs/Usage.md).

```swift
import PositronicKit
import PKShared

// Minimal — all stores default to in-memory:
let chat = PositronicKit(llmService: myLLM)

// Production — grouped persistence and grouped runtime wiring:
let chat = PositronicKit(
    llmService: myLLM,
    persistence: .init(
        messageStore: myMessageStore,
        timelinePersistence: myTimelinePersistence,
        workspacePersistence: myWorkspacePersistence,
        memoryStore: myMemoryStore,
        toolPersistence: myToolPersistence,
        agentInstanceStore: myAgentInstanceStore,
        requestOriginStore: myRequestOriginStore
    ),
    embeddingService: myEmbeddingService,
    runtime: .init(
        workspaceCreator: myWorkspaceCreator
    )
)

let stream = try await chat.run(
    timelineId: timelineId,
    message: "Hello!"
)

for try await event in stream {
    // Process chat events
}
```
