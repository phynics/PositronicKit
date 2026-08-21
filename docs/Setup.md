# PositronicKit Next / v4 Setup Guide

This guide follows `main` and describes unreleased v4 APIs. The
[stable `3.7.0` documentation](https://github.com/phynics/PositronicKit/blob/3.7.0/docs/Setup.md)
is immutable and remains the production default.

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
| Typed JSON / schema-first integrations | `PKContracts` structured output types, optionally with the runtime later |

## 2. Facade Configuration

`PositronicKit` is configured through its initializers. The runtime composes its internal graph from explicit services and stores, so callers do not rely on a shared dependency container.

### Required Services
The only required service is a value conforming to both `LLMStreamClient` and
`LLMUtilityClient`, passed as `languageModel`.

Everything else has in-memory defaults suitable for local development and tests.

### Minimal Configuration

Use the simplified facade initializer for prototyping or test harnesses:

```swift
import PositronicKit

let kit = PositronicKit(languageModel: myLanguageModel)
```

### Production Configuration

When you have a real persistence layer, prefer the grouped persistence initializer so the supported facade stays explicit:

```swift
import PositronicKit
import PKContracts

let kit = PositronicKit(configuration: .init(
    provider: .init(
        languageModel: myLanguageModel,
        embeddingService: myEmbeddingService
    ),
    persistence: .init(
        runtimeRepository: myThreadRuntimeRepository,
        workspacePersistence: myWorkspaceStore,
        agentStore: myAgentStore,
        requestOriginStore: myRequestOriginStore
    ),
    runtime: .init(
        workspaceProfile: .hostManaged(root: myWorkspaceRoot, seedNotes: .default),
        workspaceCreator: myWorkspaceCreator,
        customization: myRuntimeCustomization
    )
))
```

The grouped `configuration:` path is the supported production setup. A
`ThreadRuntimeRepository` is the atomic owner for Thread history and Turn transitions;
`RuntimeConfiguration` groups Workspace provisioning, tool policy, diagnostics, degradation, and
`RuntimeCustomization`. Consumers use `kit.threads`, `kit.agents`, `kit.workspaces`, and
`kit.model`; concrete coordinators and the model-round machinery remain internal.

Use `RuntimeCustomization` for the four bounded integration roles. Managed identity continuity is
provided by `AgentContextSource`; additive, namespaced prompt context comes from
`TurnContextSource`; `AgentActivitySink` receives best-effort lifecycle facts; and
`TurnOutcomeSink` receives a terminal outcome only after the runtime repository accepts it.

Tests and host code can inject doubles directly through the facade initializers; lower-level wiring should remain inside the components you own.

### Default Tool Installation

The facade applies a configurable default tool policy:

- filesystem tools are installed automatically by the default policy
- thread observation tools are installed automatically by the default policy
- `thread_send` is installed only when an attached agent identity is present

Use `RuntimeToolPolicy` to disable any category or start with no runtime tools.

### Provider Factories

Provider modules expose compile-time factories conforming to `LLMProviderFactory`. There is no
provider registry or runtime discovery; import and select the concrete provider your application
uses, then pass the resulting client to `LLMService`. Structured-output behavior is carried by the
client; no provider or adapter registration is needed.

```swift
import PositronicKit
import PKContracts
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

Long-lived runtime services log through `Logger.module(...)` in the package-internal utility layer; prompt-assembly diagnostics are opt-in per turn via `promptAssemblyLogger` (see above).

For package-defined errors, PositronicKit uses `ErrorKit` through `PKContracts.PKError`:

- Package error types conform to `PKError`, with stable `PKErrorDomain` and `errorCode` values.
- `userFriendlyMessage` is the preferred surfaced message; when propagating nested failures, prefer `ErrorKit.userFriendlyMessage(for:)` over raw `localizedDescription`.

## 4. Best Practices

- **Immutability**: Always treat the `Context` object as immutable. If you need to accumulate state during a pipeline run, use an `actor` for thread-safe mutations.
- **Error Handling**: Implement custom errors that conform to `PKError`, use stable `PKErrorDomain`/`errorCode` values, and prefer `ErrorKit.userFriendlyMessage(for:)` when surfacing nested failures.
- **Testing**: Prefer exercising `PositronicKit` through its public initializers with injected doubles where possible.
