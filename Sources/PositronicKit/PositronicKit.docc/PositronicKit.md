# ``PKRuntime``

The transport-neutral runtime facade for PositronicKit.

## Overview

PKRuntime provides a capability-oriented public runtime entry point for model inference,
Timeline handles, agent identity, workspace catalogs, prompt assembly, and persistence. It assembles
runtime dependencies internally from explicit initializer parameters so downstream applications
integrate through normal Swift initializers instead of configuring a dependency container directly.

### Key Components

- **PKRuntime facade**: The public entry point; `model`, `timelines`, `agents`, and `workspaces`
  are the supported capability values.
- **TimelineHandle**: An identity-bound Timeline value that starts managed or explicit direct Turns.
- **TurnHandle**: A stable admitted-Turn value exposing nonthrowing events, durable outcome replay,
  and turn-scoped cancellation.
- **Persistence Layer**: A suite of domain-specific store protocols.
- **PKTool System**: Runtime-managed and host-attached tool routing over shared tool contracts.

### Language Model Readiness

Await ``ModelInferenceCapability/readiness()`` to get a local, non-network snapshot:

```swift
switch await kit.model.readiness() {
case .ready:
    enableGeneration()
case .unavailable(let reason):
    show(reason)
}
```

The snapshot distinguishes invalid configuration from a missing usable client. It does not read
credentials, mutate configuration, or guarantee that a later request will succeed. The operation
itself remains authoritative because model state can change after the check.

Use ``ModelInferenceCapability/checkHealth()`` separately when you need provider connectivity.
Health checks may perform network I/O and report only the provider's state at the time of the
check. The method throws ``ModelHealthError/unsupported`` for a custom ``LLMStreamClient`` that
does not also conform to ``HealthCheckable``. Custom clients get a configuration-based readiness
fallback; implement ``LLMStreamClient/readiness`` when the client can report a more precise state.

### Run Validation And Agent Preflight

`TimelineHandle.startTurn(_:options:)` and `TimelineHandle.startDirectTurn(_:context:options:)` perform all
request and preparation work before returning an admitted `TurnHandle`:

- `TurnOptions.maxModelRounds` must be at least `1`. Invalid values throw
  `TurnError.invalidMaxModelRounds` before timeline lookup, persistence, or provider work.
- Timeline hydration failures throw their typed `TimelineError` before input is persisted.
- Managed execution captures the Agent attached to the Timeline immediately before durable
  admission; detached managed execution throws `TurnError.managedExecutionRequiresAttachedAgent`.
- Direct execution requires a detached Timeline and an explicit `DirectTurnContext`.
- A failed preflight does not consume `requestID`; callers may retry the same request after
  repairing the dependency.

### One-Shot Parameters And Timeouts

The configurable `complete`, `completeResult`, `stream`, and structured-output `complete`
overloads accept per-call `GenerationParameters` and an `idleTimeout`. Non-`nil` per-call
parameters override the facade defaults; `nil` uses those defaults. The timeout defaults to 60
seconds, measures provider inactivity rather than total duration, and resets after each chunk.
Typed structured one-shot requests use the same provider adapter path as full runs and return a
`Decodable` value. The requested type must conform to `Decodable`, `Sendable`, and `Schemable`;
its generated schema and decoder key strategy must agree. Pass a configured `JSONDecoder` when
custom decoding is required. The `generate` overload that takes a `structuredOutput:` request
returns the provider's raw JSON string when callers need the raw payload, a hand-built schema, or
plain JSON-object mode. The overload that takes a `from:` type returns the decoded value.

Typed structured generation reports `StructuredGenerationError.schemaConstructionFailed` before
provider execution when the generated schema cannot be represented as Draft 2020-12 JSON Schema.
After a response arrives, `StructuredOutputDecodingError.invalidJSONPayload` means the payload was
not parseable even after repair, while `.decodingFailed` means valid JSON could not be decoded as
the requested type, including failures raised by custom decoding. Provider failures, idle
timeouts, and cancellation retain their existing error identities. The raw operation never decodes;
decode its payload with `StructuredOutputDecoder`.

### Timeline history

Read durable Timeline messages through ``TimelineCapability/messages(for:)``. The result is ordered
from oldest to newest by ``TimelineMessage/timestamp``. Messages with equal timestamps keep their
append order. An unknown Timeline ID returns an empty array.

```swift
let history = try await kit.timelines.messages(for: timelineID)
for message in history {
    print("\(message.messageRole): \(message.content)")
}
```

Timeline history records semantic runtime messages. `PromptJournal` observes assembled prompt state
for provider prompt reuse and does not replace Timeline history.

### Error Delivery And Cancellation

Errors are delivered at the boundary where their work occurs:

- Request validation, timeline hydration, execution-authority checks, provider-configuration
  checks, sidecar validation, and other preparation failures throw from the awaited start call
  before it returns a `TurnHandle`.
- After admission, `TurnHandle.events()` is nonthrowing. Provider and pipeline failures are
  delivered as terminal error events, while `outcome()` reads the durable terminal state.
- `complete` and `completeResult` consume provider streams internally, so both preparation and
  provider failures throw from the one-shot call. `stream` reports provider failures during
  iteration.

Cancelling a task that consumes a facade run cancels the provider task and removes the timeline's
active-task registration. Abandoning a facade `stream` iterator also cancels its provider.
Cancellation of `complete` and `completeResult` remains `CancellationError` rather than being
wrapped as a foreign provider failure.

### Logging And Errors

- Runtime diagnostics use `swift-log`.
- Hosts own logging bootstrap and log-level configuration.
- Prompt assembly diagnostics are enabled per turn with `TurnOptions.promptAssemblyLogger`.
- Package-defined errors conform to `PKError` and surface user-facing messages through `ErrorKit`.

## Topics

### Architecture

- <doc:ArchitectureOverview>
- <doc:PersistenceLayer>

### Runtime Surfaces

Use the module articles above for architecture and persistence guidance. Shared tool contracts and message models live in `PKContracts`, while prompt construction APIs live in `PKPrompt`.
