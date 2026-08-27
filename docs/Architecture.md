# PositronicKit Next / v5 Architecture

This guide describes the unreleased v5 architecture on `main`. The
[stable `4.0.0` architecture](https://github.com/phynics/PositronicKit/blob/4.0.0/docs/Architecture.md)
is immutable. Accepted rationale lives in the [architecture decisions](adr/); canonical terms live
in the [context map](../CONTEXT-MAP.md).

## Public shape

`PositronicKit` is the composition root. Consumers keep the facade and use four shallow capability
values:

| Capability | Responsibility |
| --- | --- |
| `kit.model` | Thread-free generation, streaming, and structured output |
| `kit.threads` | Create and open durable Threads and obtain `ThreadHandle` values |
| `kit.agents` | Create, update, attach, retire, and purge persistent Agents |
| `kit.workspaces` | Create, inspect, attach, transfer, and remove Workspaces |

`ThreadHandle` and `TurnHandle` carry identity and the operations valid for that identity. Concrete
coordinators, task registries, prompt-history registries, model-round machinery, and pipeline stages
remain implementation details. The complete product-to-guide map is generated in
[Documentation navigation](NAVIGATION.md) from `docs/catalog.json`.

## Runtime assembly

`PositronicKit` remains the single composition root. Its internal initializer resolves the
configuration once and wires the resulting graph without exposing a dependency container or a
second runtime-assembly product:

| Resolved value | Shared consumers |
| --- | --- |
| `ThreadRuntimeRepository` | `ThreadManager`, `AgentManager`, `ToolRouter`, `TurnEngine`, and Turn pipelines |
| `ThreadAuthorityCoordinator` | `ThreadManager`, Workspace catalog, `AgentManager`, and Turn admission |
| `AgentAuthorityCoordinator` | `AgentManager` and Turn admission |
| `ThreadPromptJournals` | `ThreadManager` and `TurnEngine`; prompt cache state, not Thread history |
| `TurnEventHub` | `TurnEngine` views that join the same live Turn |

An explicit cohesive repository wins over separately supplied legacy Thread and message stores.
When no cohesive repository is supplied, those independent stores remain a compatibility path and
do not provide atomic v4 Turn admission. Workspace binding resolution is explicit binding
repository first, then a binding-capable cohesive repository, then a binding-capable workspace
store, and finally an in-memory fallback.

The fallback is intentional because `WorkspaceBindingRepository` has no durability declaration.
Hosts that supply a custom cohesive repository without binding conformance must also supply the
durable binding repository explicitly; `validateDurability()` cannot classify that boundary.

`reconfigured(languageModel:generationParameters:)` creates a new provider-facing view while
preserving the Thread manager, its task and Workspace execution coordinators, authority
coordinators, PromptJournal registry, and Turn event hub. `AgentManager`, `ToolRouter`, and
`TurnEngine` are rebuilt so the view can carry its replacement provider and other view-specific
configuration while retaining those shared identities. A separate `RuntimeAssembly` module is not
justified until it owns a semantic normalized graph and has an independent implementation or test
seam; extracting a wrapper around `KitDependencies` would only rename the existing transport
snapshot.

## Domain model

- A **Thread** is the durable, append-only history boundary.
- A **Turn** is one admitted execution on a Thread. Its authority and context are captured at
  admission and remain immutable until the Turn reaches a terminal outcome.
- An **Agent** is persistent identity, instructions, and continuity. It is not independently
  callable. Every Agent owns one primary Thread and one primary Workspace and may attach to many
  ordinary Threads; a Thread attaches at most one Agent.
- A **Workspace** is a runtime-addressable capability boundary. An ordinary Workspace binds
  exclusively to one Thread. Agent primary Workspaces remain Agent-owned rather than ordinary
  bindings.

Thread semantic history and `PromptJournal` have different jobs. Thread history records durable
runtime facts. `PromptJournal` observes assembled prompt state so providers can reuse stable prompt
prefixes; it never becomes semantic history.

## Turn admission and execution

There are two explicit execution paths:

1. `ThreadHandle.startTurn(message:)` admits a managed Turn. The Thread must have an attached,
   active Agent. Core resolves the Agent, captures identity and context, and records the authority
   snapshot atomically.
2. `ThreadHandle.startDirectTurn(message:context:)` admits a direct Turn on a detached Thread. The
   caller supplies the complete `DirectTurnContext`, including an intentional empty system prompt
   when appropriate. Direct Turns still capture ordinary Workspaces bound to the Thread for
   `call_tool` routing; they bypass Agent identity and Agent context.

Both return a `TurnHandle`. `events()` is a nonthrowing future-event stream, `outcome()` joins the
durable terminal result, and `cancel()` targets that Turn. The advanced request-shaped `run(_:)`
seam remains available for sidecars and other per-Turn options.

Managed preparation fails closed when required Agent context cannot be produced. Identity or
instruction changes affect the next admitted Turn, never an active one. Direct Turns bypass Agent
context entirely.

## Durability

`ThreadRuntimeRepository` is the atomic owner for Thread history and Turn transitions. Admission,
including the optional input `ThreadMessage`, tool intent and result ordering, terminal outcomes,
notices, and Request-ID uniqueness cross one repository boundary. A failed admission exposes
neither the Turn nor its input; retrying the same Request ID and fingerprint joins or replays the
existing record without duplicating the input. The prompt builder recognizes an input already
committed by admission and includes it once. `completeTurn` atomically appends a normal terminal
assistant message with its outcome. History is append-only; state changes are represented by new
durable facts, not edits to earlier entries. Pending tool-call and partial assistant rows are
intermediate recovery records and remain separate from the normal terminal message boundary.

`PositronicKit.PersistenceConfiguration` accepts the cohesive repository and the remaining stores.
The in-memory configuration implements the same contracts for tests and prototypes. Independent
Thread/message stores remain a legacy path without the v4 admission guarantee; production hosts
must provide a cohesive repository for crash-safe Turns and should reject mixed durability through
their deployment policy even though the facade reports it as a warning.

## Workspace authority and tool routing

An ordinary Workspace may be bound to only one Thread. Binding, transfer, and release are durable
operations. Execution is serialized per Workspace inside the process, so two admitted calls cannot
mutate the same Workspace concurrently.

Managed and direct Turns expose one provider-facing dispatcher named `call_tool`. At admission the
runtime captures the authorized ordinary Thread-bound Workspace IDs, labels, tool descriptions, and
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
| `AgentActivitySink` | Best-effort Agent lifecycle integration; does not mutate Thread history |
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

Observation is outward projection, never an alternate write path. `PKObservable.ThreadController`
consumes public handles and events. A Workspace tool result remains semantic history only on the
Thread whose Turn executed it; the runtime does not mirror that activity into an Agent's private
Thread.

Asynchronous mutable state belongs behind actors, synchronous snapshots behind
`Synchronization.Mutex`, and repeated signals in `AsyncStream`. Reviewed exceptions are recorded in
the [concurrency exception manifest](Concurrency/exception-manifest.md) and enforced by SwiftLint.
