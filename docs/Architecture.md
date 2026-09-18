# PositronicKit Next / v5 Architecture

This guide describes the unreleased v5 architecture on `main`. The
[stable `6.0.0` architecture](https://github.com/phynics/PositronicKit/blob/6.0.0/docs/Architecture.md)
is immutable. Accepted rationale lives in the [architecture decisions](adr/); canonical terms live
in the [context map](../CONTEXT-MAP.md).

## Public shape

`PKRuntime` is the composition root. Consumers keep the facade and use four shallow capability
values:

| Capability | Responsibility |
| --- | --- |
| `kit.model` | Timeline-free generation, streaming, and structured output |
| `kit.timelines` | Create and open durable Timelines and obtain `TimelineHandle` values |
| `kit.agents` | Create, update, attach, retire, and purge persistent Agents |
| `kit.workspaces` | Create, inspect, attach, transfer, and remove Workspaces |

`TimelineHandle` and `TurnHandle` carry identity and the operations valid for that identity. Concrete
coordinators, task registries, prompt-history registries, model-round machinery, and pipeline stages
remain implementation details. The complete product-to-guide map is generated in
[Documentation navigation](NAVIGATION.md) from `docs/catalog.json`.

## Runtime assembly

`PKRuntime` remains the single composition root. Its internal initializer resolves the
configuration once and wires the resulting graph without exposing a dependency container or a
second runtime-assembly product:

| Resolved value | Shared consumers |
| --- | --- |
| `TimelineRuntimeRepository` | `TimelineManager`, `AgentManager`, `ToolRouter`, `TurnEngine`, and Turn pipelines |
| `TimelineAuthorityCoordinator` | `TimelineManager`, Workspace catalog, `AgentManager`, and Turn admission |
| `AgentAuthorityCoordinator` | `AgentManager` and Turn admission |
| `TimelinePromptJournals` | `TimelineManager` and `TurnEngine`; prompt cache state, not Timeline history |
| `TurnEventHub` | `TurnEngine` views that join the same live Turn |

Every Turn execution path receives the same cohesive repository. Independent Timeline and message
stores may still support standalone managers that cannot execute a Turn, but they cannot be
assembled into `PKRuntime`, `TurnEngine`, `ToolRouter`, or a Turn pipeline. Workspace binding
resolution is explicit binding repository first, then a binding-capable cohesive repository, then
a binding-capable workspace store, and finally an in-memory fallback.

The fallback is intentional because `WorkspaceBindingRepository` has no durability declaration.
Hosts that supply a custom cohesive repository without binding conformance must also supply the
durable binding repository explicitly; `validateDurability()` cannot classify that boundary.

`reconfigured(languageModel:generationParameters:)` creates a new provider-facing view while
preserving the Timeline manager, its task and Workspace execution coordinators, authority
coordinators, PromptJournal registry, and Turn event hub. `AgentManager`, `ToolRouter`, and
`TurnEngine` are rebuilt so the view can carry its replacement provider and other view-specific
configuration while retaining those shared identities. A separate `RuntimeAssembly` module is not
justified until it owns a semantic normalized graph and has an independent implementation or test
seam; extracting a wrapper around `KitDependencies` would only rename the existing transport
snapshot.

## Domain model

- A **Timeline** is the durable, append-only history boundary; `TimelineRecord` is its persisted metadata value.
- A **Turn** is one admitted execution on a Timeline. Its authority and context are captured at
  admission and remain immutable until the Turn reaches a terminal outcome.
- An **Agent** is persistent identity, instructions, and continuity. It is not independently
  callable. Every Agent owns one primary Timeline and one primary Workspace and may attach to many
  ordinary Timelines; a Timeline attaches at most one Agent.
- A **Workspace** is a runtime-addressable capability boundary. An ordinary Workspace binds
  exclusively to one Timeline. Agent primary Workspaces remain Agent-owned rather than ordinary
  bindings.

Timeline semantic history and `PromptJournal` have different jobs. Timeline history records durable
runtime facts. `PromptJournal` observes assembled prompt state so providers can reuse stable prompt
prefixes; it never becomes semantic history.

## Turn admission and execution

There are two explicit execution paths:

1. `TimelineHandle.startTurn(_:options:)` admits a managed Turn. The Timeline must have an attached,
   active Agent. Core resolves the Agent, captures identity and context, and records the authority
   snapshot atomically.
2. `TimelineHandle.startDirectTurn(_:context:options:)` admits a direct Turn on a detached Timeline. The
   caller supplies the complete `DirectTurnContext`, including an intentional empty system prompt
   when appropriate. Direct Turns still capture ordinary Workspaces bound to the Timeline for
   `call_tool` routing; they bypass Agent identity and Agent context.

Both return a `TurnHandle`. `events()` is a nonthrowing future-event stream, `outcome()` joins the
durable terminal result, and `cancel()` targets that Turn. Per-Turn options such as sidecars,
tools, and generation parameters are supplied through `TurnOptions`; the handle supplies the
Timeline identity.

Managed preparation fails closed when required Agent context cannot be produced. Identity or
instruction changes affect the next admitted Turn, never an active one. Direct Turns bypass Agent
context entirely.

## Durability

`TimelineRuntimeRepository` is the atomic owner for Timeline history and Turn transitions. Admission,
including the optional input `TimelineMessage`, tool intent and result ordering, terminal outcomes,
notices, and Request-ID uniqueness cross one repository boundary. A failed admission exposes
neither the Turn nor its input; retrying the same Request ID and fingerprint joins or replays the
existing record without duplicating the input. The prompt builder recognizes an input already
committed by admission and includes it once. `completeTurn` atomically appends a normal terminal
assistant message with its outcome. History is append-only; state changes are represented by new
durable facts, not edits to earlier entries. Pending tool-call and partial assistant rows are
intermediate recovery records and remain separate from the normal terminal message boundary.

Terminal finalization is runtime-owned (ADR 0010). The Turn loop hands its terminal decision and a
snapshot of partial output to a `TurnFinalizer`, which commits the outcome, runs the sinks, and
emits the terminal event, serialized per Timeline. Because the finalizer is not the cancelled Turn
task, cancelling a Turn cannot cancel its commit, and a host store that hangs during the commit
bounds how long the Timeline stays busy, not how long eviction takes. Liveness is in-process: the
runtime assumes one process owns a repository at a time, classifies an active Turn it does not own
as an orphan, interrupts a commit that has stayed pending past
`RuntimeConfiguration.terminalCommitStallLimit`, and quarantines a Timeline only when an unresolved
side-effecting tool intent makes a blind retry unsafe.

`PKRuntime.PersistenceConfiguration` requires the cohesive repository and accepts the remaining
stores. The in-memory configuration implements the same contracts for tests and prototypes. The
runtime has no independent Timeline/message-store Turn path, so admission, history, replay, and
terminal truth always share one atomic owner.

## Workspace authority and tool routing

An ordinary Workspace may be bound to only one Timeline. Binding, transfer, and release are durable
operations. Execution is serialized per Workspace inside the process, so two admitted calls cannot
mutate the same Workspace concurrently.

Managed and direct Turns expose one provider-facing dispatcher named `call_tool`. At admission the
runtime captures the authorized ordinary Timeline-bound Workspace IDs, labels, tool descriptions, and
schemas. Managed Turns additionally capture the Agent primary Workspace. A call names a tool,
optionally names its Workspace with `at`, and supplies `arguments`. The Workspace may be omitted
only when exactly one captured Workspace provides that tool. Ambiguity produces a corrective result
and a durable notice; it never selects a Workspace by iteration order. Ordinary bindings are
revalidated immediately before a side effect, so a released or transferred binding fails closed.

Runtime tools and request-scoped tools are separate from Workspace dispatch. The reserved
`call_tool` name cannot be registered by a consumer.

## Runtime customization

`RuntimeCustomization` contains four typed roles:

| Role | Contract |
| --- | --- |
| `AgentContextSource` | Authoritative managed-Agent context; failure aborts preparation |
| `TurnContextSource` | Optional bounded, namespaced additions for an admitted Turn |
| `AgentActivitySink` | Best-effort Agent lifecycle integration; does not mutate Timeline history |
| `TurnOutcomeSink` | Post-terminal integration after the durable outcome is accepted |

The bundled Agent context source reads stable instructions and a bounded Notes catalog from the
Agent primary Workspace. Filesystem memory is an implementation choice, not a mandatory domain
dependency. Sink failures are recorded for the host and do not rewrite the originating Turn
outcome.

The v4 boundary intentionally has no automatic semantic-memory retrieval stage. Hosts that already
have a retrieval system provide its bounded result through `AgentContextSource`; per-Turn additions
use `TurnContextSource`; model-directed note access uses Workspace file tools. The prompt layer's
primitive leaves and durable tool diagnostics remain implementation details. See the accepted
[memory and prompt boundaries decision](adr/0006-memory-retrieval-and-prompt-boundaries.md) for
the downstream audit and migration boundary.

## Module boundaries

- `PKContracts` owns runtime-neutral provider, tool, structured-output, and diagnostic
  contracts. It imports no PositronicKit project target.
- `PKPrompt` owns prompt IR, composition, assembly, rendering, compression, and journaling.
- `PositronicKit` owns domain state, orchestration, durability, and Workspace dispatch.
- Provider products adapt concrete services to `PKContracts`; they do not import the runtime.
- `PKObservable` projects runtime state outward for UI consumers.
- `PKTestSupport` provides ordinary-import fixtures for downstream test targets.
- `PKUtilities` supports package implementation but is not a public product.

Embedding generation and vector retrieval are intentionally outside the current package surface.
They remain a future direction and require a separately owned contract and consumer story.

The package manifest, public-product consumer, DocC modules, generated navigation, and CI catalog
check must agree on this graph.

## Observation and concurrency

Observation is outward projection, never an alternate write path. `PKObservable.TimelineController`
consumes public handles and events. A Workspace tool result remains semantic history only on the
Timeline whose Turn executed it; the runtime does not mirror that activity into an Agent's private
Timeline.

Asynchronous mutable state belongs behind actors, synchronous snapshots behind
`Synchronization.Mutex`, and repeated signals in `AsyncStream`. Reviewed exceptions are recorded in
the [concurrency exception manifest](Concurrency/exception-manifest.md) and enforced by SwiftLint.
