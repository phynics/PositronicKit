# PositronicKit setup

This guide follows `main` and describes unreleased v5 APIs. The
[stable `5.1.0` documentation](https://github.com/phynics/PositronicKit/blob/5.1.0/docs/Setup.md)
is immutable and remains the production default.

## Choose an entry point

Pick the smallest product that matches your need:

| Need | Start with |
| --- | --- |
| Prompt composition, rendering, or journaling without the runtime | `PKPrompt` |
| Single-process app or CLI agent runtime | The `PositronicKit` facade |
| Runtime + OpenAI/OpenRouter/Ollama/Anthropic convenience setup | Add the matching provider package |
| On-device Apple Intelligence models (no key, no network) | Add `PKFoundationModelsProvider` and pass `FoundationModelsClient` as the language model. This requires macOS 26+ on Apple Silicon with Apple Intelligence enabled and reports unavailability as a typed error |
| Host-owned workspace execution/attachment behavior | `PositronicKit` + your own `WorkspaceFactory` / `WorkspaceProvider` (optionally `WorkspaceToolProvider` and `WorkspaceFileProvider`) |
| Typed JSON / schema-first integrations | `PKContracts` structured output types, optionally with the runtime later |

## Configure the facade

`PositronicKit` is configured through its initializers. The runtime composes its internal graph from explicit services and stores, so callers do not rely on a shared dependency container.

### Required services
The provider requires a value conforming to `LLMStreamClient`, passed as `languageModel`. A
grouped production configuration also requires one `ThreadRuntimeRepository`, which atomically
owns Thread history and Turn transitions. Other stores have in-memory defaults suitable for local
development and tests.

### Minimal configuration

Use the simplified facade initializer for prototyping or test harnesses:

```swift
import PositronicKit

let kit = PositronicKit(languageModel: myLanguageModel)
```

Before enabling a generation control, use the local readiness snapshot. It does not read
credentials, mutate configuration, or perform network I/O:

```swift
switch await kit.model.readiness() {
case .ready:
    enableGeneration()
case .unavailable(let reason):
    show(reason)
}
```

Use health separately when you want an explicit provider connectivity check:

```swift
do {
    let health = try await kit.model.checkHealth()
    print("Model health: \(health.rawValue)")
} catch ModelHealthError.unsupported {
    print("This custom model does not provide a connectivity check.")
}
```

`checkHealth()` may perform network I/O and reports the provider's state at that moment. A custom
`LLMStreamClient` gets a configuration-based readiness fallback. Implement its `readiness`
property when it can distinguish a configured but unusable client. Conform to `HealthCheckable`
to provide explicit health checks. Neither operation guarantees that a later generation request
will succeed.

### Production configuration

When you have a real persistence layer, use the grouped initializer so the supported facade stays explicit:

```swift
import PositronicKit
import PKContracts

let kit = PositronicKit(configuration: .init(
    languageModel: myLanguageModel,
    persistence: .init(
        runtimeRepository: myThreadRuntimeRepository,
        workspacePersistence: myWorkspaceStore,
        toolPersistence: myToolPersistence,
        agentStore: myAgentStore,
        requestOriginStore: myRequestOriginStore,
        workspaceBindingRepository: myWorkspaceBindingRepository
    ),
    runtime: .init(
        workspaceProfile: .hostManaged(root: myWorkspaceRoot, seedNotes: .default),
        workspaceCreator: myWorkspaceCreator,
        customization: myRuntimeCustomization
    )
))
```

The grouped `configuration:` path is the supported production setup. A
`ThreadRuntimeRepository` is the atomic owner for Thread history and Turn transitions, including
Turn admission with the input message and normal terminal message/outcome completion.
`RuntimeConfiguration` groups Workspace provisioning, tool policy, diagnostics, degradation, and
`RuntimeCustomization`. Consumers use `kit.threads`, `kit.agents`, `kit.workspaces`, and
`kit.model`. Concrete coordinators and the model-round machinery remain internal.

For a fully durable setup, call `PersistenceConfiguration.fullyPersistent(...)` and provide every
store, including `workspaceBindingRepository`. Use the regular initializer when some stores are
intentionally in memory.

Set `RuntimeConfiguration.streamTimeout` to control the maximum idle interval between streamed
model chunks. It defaults to 60 seconds and applies only while a provider stream is active. It is
not a total Turn duration limit.

Turn execution always uses the configured `ThreadRuntimeRepository`. Independent `messageStore`
and `threadPersistence` values are not accepted by the facade or its Turn machinery. Standalone
managers that cannot execute a Turn may still use their narrower persistence seams.

Use `RuntimeCustomization` for the four bounded integration roles. Managed identity continuity is
provided by `AgentContextSource`. Additive, namespaced prompt context comes from
`TurnContextSource`. `AgentActivitySink` receives best-effort lifecycle facts, and
`TurnOutcomeSink` receives a terminal outcome only after the runtime repository accepts it.

Tests and host code can inject doubles directly through the facade initializers. Keep lower-level
wiring inside the components you own.

### Reuse persistence conformance suites

Downstream adapters can use the public runners in `PKTestSupport` from their own Swift Testing
target. The runners are ordinary async or throwing functions, not discovered tests, so the
downstream target owns test names, tags, and source locations:

```swift
import PKTestSupport
import PositronicKit

@Test("the workspace adapter conforms")
func workspaceAdapterConforms() async throws {
    try await WorkspaceStoreConformanceSuite.run {
        MyWorkspaceStore()
    }
}
```

The six available runners cover `ThreadRuntimeRepository`, `WorkspaceStore`,
`ToolPersistenceProtocol`, `AgentStoreProtocol`, `RequestOriginStoreProtocol`, and
`WorkspaceFactory`. Each runner creates a fresh fixture for every scenario and runs scenarios
sequentially. The suites make durable behavior normative: ID-based replacement, targeted and
idempotent deletion, scope-aware tool queries, attached-thread filtering, atomic Turn admission
and terminal transitions, and complete workspace-reference preservation. They intentionally do
not prescribe result ordering, storage technology, exact tool-source presentation strings,
`includeTools` projection details, unsupported factory inputs, or the self-reported `isDurable`
capability.

### Install default tools

The facade applies a configurable default tool policy:

- filesystem tools are installed automatically by the default policy
- thread observation tools are installed automatically by the default policy
- `thread_send` is installed only when an attached agent identity is present

Use `RuntimeToolPolicy` to disable any category or start with no runtime tools.

### Use provider factories

Provider modules expose compile-time factories conforming to `LLMProviderFactory`. There is no
provider registry or runtime discovery. Import and select the concrete provider your application
uses, then pass its configured value to `PositronicKit`. Structured-output behavior is carried by
the client. No provider or adapter registration is needed.

```swift
import PositronicKit
import PKOpenAIProvider

let provider = PKOpenAIProvider.makeConfiguredProvider(
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "",
    model: "gpt-4o"
)
let core = PositronicKit(provider: provider)
```

The same shape is available for OpenRouter, Ollama, and Anthropic:

```swift
import PKAnthropicProvider

let provider = PKAnthropicProvider.makeConfiguredProvider(
    apiKey: "sk-ant-...",
    model: "claude-sonnet-4-5"
)
let core = PositronicKit(provider: provider)
```

### Run a local example

The repository's `PositronicKitExamples` executable uses a deterministic local model, so you can
exercise the full Thread and Turn path without an API key or network access:

```bash
swift run PositronicKitExamples
```

For custom timeouts, generation parameters, attribution, or multiple model-tier clients, use the
advanced `PKContracts.ProviderConfiguration`, `LLMClientSet`, and `LLMService` initializers. Ordinary
consumers do not need to construct that client topology.

Foundation Models is intentionally separate from this HTTP-provider value. Its on-device session
has no API key, endpoint, or selectable network model, so construct `FoundationModelsClient` from
`PKFoundationModelsProvider` and pass it through `PositronicKit(languageModel:)`. The client
reports unsupported platforms and unavailable model sessions through its typed errors.

## Configure logging and errors

PositronicKit uses `swift-log` as its only logging API. Library code never calls
`LoggingSystem.bootstrap(...)`. The downstream app, CLI, or test owns bootstrap and log-level
selection:

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

let provider = PKOpenAIProvider.makeConfiguredProvider(
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
)
let core = PositronicKit(provider: provider)
```

Long-lived runtime services log through `Logger.module(...)` in the package-internal utility layer.
Prompt-assembly diagnostics are opt-in per turn through `promptAssemblyLogger` (see above).

For package-defined errors, PositronicKit uses `ErrorKit` through `PKContracts.PKError`:

- Package error types conform to `PKError`, with stable `PKErrorDomain` and `errorCode` values.
- `ThreadRuntimeRepositoryError` uses `PKErrorDomain.thread` codes `6101` through `6117`. Code `6118` is reserved.
- `WorkspaceBindingRepositoryError` uses `PKErrorDomain.workspace` codes `3101` through `3103`.
- `userFriendlyMessage` is the preferred surfaced message. When propagating nested failures, prefer
  `ErrorKit.userFriendlyMessage(for:)` over raw `localizedDescription`.
- Durable `TurnOutcome.failed` values store the same user-facing message used to describe the original failure.

## Test and handle errors

- Prefer exercising `PositronicKit` through its public initializers with injected doubles.
- Make custom errors conform to `PKError` and give them stable `PKErrorDomain` and `errorCode`
  values.
- Prefer `ErrorKit.userFriendlyMessage(for:)` when surfacing nested failures.
