# MonadCore Architecture

MonadCore is built on a modular, asynchronous processing architecture designed for scalability, thread safety, and clear separation of concerns.

## 1. The Pipeline Pattern

The core processing logic in MonadCore follows a generic **Pipeline** pattern. This allows for complex workflows (like a chat turn) to be broken down into discrete, reusable stages.

### PipelineStage Protocol
A stage is any type that conforms to the `PipelineStage` protocol:
```swift
public protocol PipelineStage<Context, Event>: Sendable {
    associatedtype Context: Sendable
    associatedtype Event: Sendable

    var id: String { get }
    func process(_ context: Context) async throws -> AsyncThrowingStream<Event, Error>
}
```

### Pipeline Execution
The `Pipeline` class orchestrates the execution of these stages:
1. **Sequential Execution**: Primary stages are executed one after another.
2. **Stream Merging**: The pipeline merges the `AsyncThrowingStream` from each stage into a single continuous stream for the caller.
3. **Cleanup Stages**: Stages registered via `.cleanup()` are guaranteed to run even if a primary stage fails, ensuring system integrity (e.g., closing database connections or logging final state).

## 2. Context & State Management

MonadCore uses a dual-structure approach to state management during a pipeline execution.

### ChatTurnContext (Immutable Snapshot)
The `ChatTurnContext` is a thread-safe, immutable struct that represents the state of a chat turn at a specific point in time. It contains:
- Session-level configuration (Timeline ID, Model name, Max turns).
- Turn-specific data (Current messages, Available tools).
- A reference to the mutable `TurnOutputs`.

### TurnOutputs (Actor-Isolated Mutable State)
Because multiple stages might need to update the results of a turn concurrently (e.g., a streaming stage and a background tool-call extraction stage), mutable state is isolated within the `TurnOutputs` actor.
- **Thread Safety**: All mutations (appending thinking, updating usage metrics) are performed via `await` calls to the actor.
- **Safe Persistence**: At the end of the pipeline, the `TurnOutputs` are used to finalize the message state and persist it to the database.

## 3. Dependency Injection

MonadCore leverages PointFree's `Dependencies` library for robust service management.

- **Centralized Registry**: All shared services (LLM, Storage, Tools) are registered in `DependencyValues`.
- **Property Wrappers**: Components access services via the `@Dependency` property wrapper.
- **Testability**: Dependencies can be easily overridden in tests or previews using `withDependencies`.

## 4. Execution Flow: The Chat Engine

The `ChatEngine` is the primary orchestrator that uses the Pipeline to handle user interactions.

1. **Initialization**: Prepares the session and initial context.
2. **ReAct Loop**: Runs a loop (`runChatLoop`) that continues as long as the agent needs to "think" or execute tools.
3. **Pipeline Construction**: For each turn, it builds a pipeline consisting of:
   - `LLMStreamingStage`: Streams the raw response from the LLM.
   - `ToolCallExtractionStage`: Parses the stream for potential tool calls.
   - `MessagePersistenceStage`: Saves the final result once the stream completes.
