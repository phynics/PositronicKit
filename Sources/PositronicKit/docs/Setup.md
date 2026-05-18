# PositronicKitCore Setup Guide

This guide describes how to configure and use PositronicKitCore in your application.

## 1. Dependency Configuration

`PositronicKitCore` uses PointFree's `Dependencies` library internally, but normal consumers should configure the runtime through `PositronicKitCore` initializers rather than mutating `DependencyValues` directly.

### Required Services
The only required service is:
1. `llmService`: Provides access to an LLM provider.

Everything else has in-memory defaults suitable for local development and tests.

### Minimal Configuration

Use the simplified facade initializer for prototyping or test harnesses:

```swift
import PositronicKit

let chat = PositronicKitCore(
    llmService: MyLLMServiceLive()
)
```

### Production Configuration

When you have a real persistence layer, prefer the grouped persistence initializer so the supported facade stays explicit:

```swift
import PositronicKit
import PKShared

let chat = PositronicKitCore(
    llmService: MyLLMServiceLive(),
    persistence: .init(
        messageStore: MyMessageStoreLive(),
        timelinePersistence: MyTimelineStoreLive(),
        workspacePersistence: MyWorkspaceStoreLive(),
        memoryStore: MyMemoryStoreLive(),
        toolPersistence: MyToolStoreLive(),
        agentInstanceStore: MyAgentStoreLive(),
        requestOriginStore: MyRequestOriginStoreLive(),
        agentTemplateStore: MyTemplateStoreLive()
    ),
    embeddingService: MyEmbeddingServiceLive(),
    runtime: .init(
        timelineManager: MyTimelineManagerLive(),
        toolRouter: MyToolRouterLive(),
        workspaceRoot: myWorkspaceRoot
    )
)
```

The longer per-store initializer still exists, but the grouped `persistence:` + `runtime:` path is the clearer supported production setup for most adopters.

Direct `withDependencies` configuration is still useful in tests or advanced internal integrations, but it is not the primary public integration path.

### Default Tool Installation

`TimelineManager` currently applies a fixed default tool policy for v1:

- filesystem tools are installed automatically
- timeline observation tools are installed automatically
- `timeline_send` is installed only when an attached agent identity is present

These defaults are part of the current runtime contract and are not exposed as a separate configuration surface yet.

## 2. Logging

PositronicKit uses `swift-log` only.

- The library does not call `LoggingSystem.bootstrap(...)`.
- Your host application or CLI should bootstrap logging once, at process startup.
- Runtime services emit normal operational logs through `Logger.module(...)`.
- Prompt assembly emits verbose diagnostics only when you pass a `Logger` through `PromptAssemblyOptions`.

```swift
import Logging
import PositronicKit

LoggingSystem.bootstrap { label in
    StreamLogHandler.standardOutput(label: label)
}

let logger = Logger(label: "com.example.prompt")
let options = PromptAssemblyOptions(logger: logger)
```

## 3. Setting Up a Pipeline

The runtime uses the generic `Pipeline` type internally for chat turns, prompt assembly, and context gathering. You can also use `Pipeline` directly for independent workflows.

### Step 1: Define Your Context and Events
```swift
struct MyContext: Sendable {
    var state: String
}

enum MyEvent: Sendable {
    case dataReady(String)
}
```

### Step 2: Implement a Pipeline Stage
```swift
struct MyStage: PipelineStage {
    let id = "my-stage"
    func process(_ context: MyContext) async throws -> AsyncThrowingStream<MyEvent, Error> {
        return AsyncThrowingStream { continuation in
            continuation.yield(.dataReady("Processed: " + context.state))
            continuation.finish()
        }
    }
}
```

### Step 3: Initialize and Execute the Pipeline
```swift
let pipeline = Pipeline<MyContext, MyEvent>()
    .add(MyStage())
    .cleanup(LogCleanupStage()) // Cleanup stage runs even on failure

let context = MyContext(state: "Initial State")
let stream = pipeline.execute(context)

for try await event in stream {
    print("Received event: \(event)")
}
```

## 4. Best Practices

- **Immutability**: Always treat the `Context` object as immutable. If you need to accumulate state during a pipeline run, use an `actor` for thread-safe mutations.
- **Error Handling**: Implement custom errors that conform to `PKError`, use stable `PKErrorDomain`/`errorCode` values, and prefer `ErrorKit.userFriendlyMessage(for:)` when surfacing nested failures.
- **Testing**: Use `withDependencies` in tests when you need to override internals, but prefer exercising `PositronicKitCore` through its public initializers where possible.
