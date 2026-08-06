# ``PositronicKit``

The transport-neutral runtime facade for PositronicKit.

## Overview

PositronicKit provides the public runtime entry point for timeline management, prompt assembly, context gathering, tool execution, and persistence. It assembles runtime dependencies internally from explicit initializer parameters so downstream applications integrate through normal Swift initializers instead of configuring a dependency container directly.

### Key Components

- **PositronicKit facade**: The public entry point; `run(_ request:)` drives a chat turn end to end.
- **TimelineManager**: Coordinates timeline lifecycle, context gathering, and workspace attachment.
- **Persistence Layer**: A suite of domain-specific store protocols.
- **Tool System**: Runtime-managed and host-attached tool routing (`ToolRouter`) over shared tool contracts.

### Language Model Readiness

Await ``PositronicKit/isLanguageModelConfigured`` to determine whether the injected language
model currently reports usable provider configuration. The value is read live from the model;
the facade does not expose provider details, credentials, or configuration mutation. This is a
configuration-readiness hint, not a connectivity probe or a guarantee that a subsequent request
will succeed. The operation itself remains authoritative because model state can change after the
check.

### Run Validation And Agent Preflight

``PositronicKit/run(_:)`` performs all synchronous request and preparation work before returning
its event stream:

- `ChatRunRequest.maxTurns` must be at least `1`. Invalid values throw
  `ChatRunError.invalidMaxTurns` before timeline lookup, persistence, or provider work.
- Timeline hydration failures throw their typed `TimelineError` before input is persisted.
- When `agentInstanceID` is supplied, the runtime resolves the agent once after timeline
  resolution and before provider readiness or input persistence. The default `.failRequired`
  policy throws `AgentInstanceError.instanceNotFound` for a missing agent. With
  `.continueWithWarnings`, the turn continues without that agent and the initial
  generation-context event carries an agent diagnostic.
- A failed required-agent preflight does not consume `sendID`; callers may retry the same send
  after repairing the missing dependency.

### One-Shot Parameters And Timeouts

The configurable `complete`, `completeResult`, `stream`, and structured-output `complete`
overloads accept per-call `GenerationParameters` and an `idleTimeout`. Non-`nil` per-call
parameters override the facade defaults; `nil` uses those defaults. The timeout defaults to 60
seconds, measures provider inactivity rather than total duration, and resets after each chunk.
Structured one-shot requests use the same provider adapter path as full runs and return the raw
structured payload for decoding.

### Error Delivery And Cancellation

Errors are delivered at the boundary where their work occurs:

- Request validation, timeline hydration, agent preflight, provider-configuration checks,
  sidecar validation, and other preparation failures throw from the awaited `run(_:)` call before
  it returns a stream.
- Provider and pipeline failures that happen after `run(_:)` returns throw while the returned
  stream is iterated. Use `ChatEvent.ErrorIdentity.extracting(from:)` to classify nested causal
  failures without matching message text. Foreign provider failures retain their original cause
  and expose the stable LLM domain/code identity (`PKErrorDomain.llm`, `1005`).
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
- Prompt assembly diagnostics are enabled per turn with `PositronicKit.run(_:)` via `ChatRunRequest.promptAssemblyLogger`.
- Package-defined errors conform to `PKError` and surface user-facing messages through `ErrorKit`.

## Topics

### Architecture

- <doc:ArchitectureOverview>
- <doc:PersistenceLayer>

### Runtime Surfaces

Use the module articles above for architecture and persistence guidance. Shared tool contracts and message models live in `PKShared`, while prompt construction APIs live in `PKPrompt`.
