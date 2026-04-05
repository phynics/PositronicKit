# MonadCore Setup Guide

This guide describes how to configure and use MonadCore in your application.

## 1. Dependency Configuration

MonadCore uses PointFree's `Dependencies` library. Before using any core services (like `ChatEngine`), you must configure the required dependencies. Accessing an unconfigured service will result in a `fatalError`.

### Required Services
The two most critical services to configure are:
1. `llmService`: Provides access to LLM providers (e.g., OpenAI).
2. `messageStore`: Handles persistence of chat messages and turn data.

### Configuration Example
To configure MonadCore at app launch or within a specific task:

```swift
import Dependencies
import MonadCore

// Override default unconfigured values in DependencyValues
withDependencies {
    $0.llmService = MyLLMServiceLive()
    $0.messageStore = MyMessageStoreLive()
} operation: {
    // Services are now safely accessible here
    let engine = ChatEngine()
    // ...
}
```

## 2. Setting Up a Pipeline

While `ChatEngine` provides a default pipeline, you can create custom pipelines for specialized tasks.

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

## 3. Best Practices

- **Immutability**: Always treat the `Context` object as immutable. If you need to accumulate state during a pipeline run, use an `actor` for thread-safe mutations.
- **Error Handling**: Implement custom errors that conform to `MonadError` for consistent error reporting across the framework.
- **Testing**: Use `withDependencies` in your unit tests to provide mock implementations of `LLMService` and `MessageStore`.
