# PositronicKit Setup Guide

This guide describes how to configure and use PositronicKit in your application.

## 1. Choosing An Entry Point

Pick the smallest surface that matches your need:

| Need | Start with |
|------|-----------|
| Prompt composition, rendering, journaling — no runtime | `PKPrompt` |
| Single-process app or CLI agent runtime | The `PositronicKit` facade |
| Runtime + OpenAI/OpenRouter/Ollama/Anthropic convenience setup | Add the matching provider package |
| On-device Apple Intelligence models (no key, no network) | Add `PKFoundationModelsProvider` — `PositronicKit(foundationModelsTools:)`; requires macOS 26+/Apple Silicon with Apple Intelligence enabled, surfaces unavailability as a typed `PKError` |
| Local embedding service | Add `PKLocalEmbeddings` |
| Host-owned filesystem/execution/attachment behavior | `PositronicKit` + your own `WorkspaceFactory` / `Workspace` |
| Typed JSON / schema-first integrations | `PKShared` structured output types, optionally with the runtime later |

## 2. Facade Configuration

`PositronicKit` is configured through its initializers. The runtime composes its internal graph from explicit services and stores, so callers do not rely on a shared dependency container.

### Required Services
The only required service is:
1. `llmService`: Provides access to an LLM provider.

Everything else has in-memory defaults suitable for local development and tests.

### Minimal Configuration

Use the simplified facade initializer for prototyping or test harnesses:

```swift
import PositronicKit

let chat = PositronicKit(
    llmService: MyLLMServiceLive()
)
```

### Production Configuration

When you have a real persistence layer, prefer the grouped persistence initializer so the supported facade stays explicit:

```swift
import PositronicKit
import PKShared

let chat = PositronicKit(
    llmService: MyLLMServiceLive(),
    persistence: .init(
        messageStore: MyMessageStoreLive(),
        threadPersistence: MyThreadStoreLive(),
        workspacePersistence: MyWorkspaceStoreLive(),
        memoryStore: MyMemoryStoreLive(),
        toolPersistence: MyToolStoreLive(),
        agentInstanceStore: MyAgentStoreLive(),
        requestOriginStore: MyRequestOriginStoreLive()
    ),
    embeddingService: MyEmbeddingServiceLive(),
    runtime: .init(
        workspaceCreator: MyWorkspaceCreatorLive(),
        workspaceRoot: myWorkspaceRoot
    )
)
```

The grouped `persistence:` + `runtime:` path is the supported production setup (the old flat per-store initializer was removed by PKFAC-002). `RuntimeConfiguration` groups the non-store runtime knobs — `workspaceCreator`, `sectionProviders`, `runtimeToolPolicy`, `workspaceRoot`, `chatTurnPlugins`, `promptInspector`, `toolApprovalGate` — not pre-built `ThreadManager`/`ToolRouter` instances; the facade is the only place those get constructed, so they can never end up wrapping different stores. Read them back afterward via `chat.threadManager` / `chat.toolRouter` if you need direct access.

Tests and host code can inject doubles directly through the facade initializers; lower-level wiring should remain inside the components you own.

### Default Tool Installation

`ThreadManager` applies a configurable default tool policy:

- filesystem tools are installed automatically by the default policy
- thread observation tools are installed automatically by the default policy
- `timeline_send` is installed only when an attached agent identity is present

Use `RuntimeToolPolicy` to disable any category or start with no runtime tools.

### Provider Factories

Provider modules expose compile-time factories conforming to `LLMProviderFactory`. There is no
provider registry or runtime discovery; import and select the concrete provider your application
uses, then pass the resulting client to `LLMService`. Structured-output behavior is carried by the
client; no provider or adapter registration is needed.

```swift
import PositronicKit
import PKShared
import PKOpenAIProvider

var providerConfig = ProviderConfiguration.makeDefault(for: .openAI)
providerConfig.apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
let configuration = LLMConfiguration(
    activeProvider: .openAI,
    providers: [.openAI: providerConfig]
)

let core = PositronicKit(
    languageModel: LLMService(
        storage: InMemoryConfigurationService(config: configuration),
        client: PKOpenAIProvider.makeClient(configuration: configuration)
    )
)
```

Or use the provider target's convenience initializer:

```swift
import PKOpenAIProvider

let core = PositronicKit(openAIKey: "sk-...")
```

## 3. Logging And Errors

PositronicKit uses `swift-log` as its only logging API. Library code never calls `LoggingSystem.bootstrap(...)` — the downstream app, CLI, or test owns bootstrap and log-level selection:

```swift
import Logging
import PositronicKit
import PKOpenAIProvider

// Bootstrap once, early in your app/CLI/test startup.
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .debug   // raise to surface runtime + prompt-assembly diagnostics
    return handler
}

let core = PositronicKit(openAIKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "")
```

Long-lived runtime services log through `Logger.module(...)` in `PKShared`; prompt-assembly diagnostics are opt-in per turn via `promptAssemblyLogger` (see above).

For package-defined errors, PositronicKit uses `ErrorKit` through `PKShared.PKError`:

- Package error types conform to `PKError`, with stable `PKErrorDomain` and `errorCode` values.
- `userFriendlyMessage` is the preferred surfaced message; when propagating nested failures, prefer `ErrorKit.userFriendlyMessage(for:)` over raw `localizedDescription`.

## 4. Setting Up a Pipeline

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

## 5. Best Practices

- **Immutability**: Always treat the `Context` object as immutable. If you need to accumulate state during a pipeline run, use an `actor` for thread-safe mutations.
- **Error Handling**: Implement custom errors that conform to `PKError`, use stable `PKErrorDomain`/`errorCode` values, and prefer `ErrorKit.userFriendlyMessage(for:)` when surfacing nested failures.
- **Testing**: Prefer exercising `PositronicKit` through its public initializers with injected doubles where possible.
