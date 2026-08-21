# PositronicKit Next / v4 Architecture

This guide describes the unreleased v4 architecture on `main`. The
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
   when appropriate.

Both return a `TurnHandle`. `events()` is a nonthrowing future-event stream, `outcome()` joins the
durable terminal result, and `cancel()` targets that Turn. The advanced request-shaped `run(_:)`
seam remains available for sidecars and other per-Turn options.

Managed preparation fails closed when required Agent context cannot be produced. Identity or
instruction changes affect the next admitted Turn, never an active one. Direct Turns bypass Agent
context entirely.

## Durability

`ThreadRuntimeRepository` is the atomic owner for Thread history and Turn transitions. Admission,
tool intent and result ordering, terminal outcomes, notices, and Request-ID uniqueness cross one
repository boundary. History is append-only; state changes are represented by new durable facts,
not edits to earlier entries.

`PositronicKit.PersistenceConfiguration` accepts the cohesive repository and the remaining stores.
The in-memory configuration implements the same contracts for tests and prototypes. Production
hosts provide durable implementations and should reject mixed durability through their deployment
policy even though the facade reports it as a warning.

## Workspace authority and tool routing

An ordinary Workspace may be bound to only one Thread. Binding, transfer, and release are durable
operations. Execution is serialized per Workspace inside the process, so two admitted calls cannot
mutate the same Workspace concurrently.

Managed Turns expose one provider-facing dispatcher named `call_tool`. At admission the runtime
captures the authorized Workspace IDs, labels, tool descriptions, and schemas. A call names a tool,
optionally names its Workspace with `at`, and supplies `arguments`. The Workspace may be omitted
only when exactly one captured Workspace provides that tool. Ambiguity produces a corrective result
and a durable notice; it never selects a Workspace by iteration order.

Runtime tools and request-scoped tools are separate from Workspace dispatch. The reserved
`call_tool` name cannot be registered by a consumer.

## Runtime customization

`RuntimeCustomization` contains four typed roles:

| Role | Contract |
| --- | --- |
| `AgentContextSource` | Authoritative managed-Agent context; failure aborts preparation |
| `TurnContextSource` | Optional bounded, namespaced additions for an admitted Turn |
| `AgentActivitySink` | Best-effort Agent lifecycle projection |
| `TurnOutcomeSink` | Post-terminal integration after the durable outcome is accepted |

The bundled Agent context source reads bounded notes from the Agent primary Workspace. Filesystem
or vector memory is an implementation choice, not a mandatory domain dependency. Sink failures are
recorded for the host and do not rewrite the originating Turn outcome.

## Module boundaries

- `PKContracts` owns runtime-neutral provider, tool, structured-output, embedding, and diagnostic
  contracts. It imports no PositronicKit project target.
- `PKPrompt` owns prompt IR, composition, assembly, rendering, compression, and journaling.
- `PositronicKit` owns domain state, orchestration, durability, and Workspace dispatch.
- Provider products adapt concrete services to `PKContracts`; they do not import the runtime.
- `PKObservable` projects runtime state outward for UI consumers.
- `PKTestSupport` provides ordinary-import fixtures for downstream test targets.
- `PKUtilities` supports package implementation but is not a public product.

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
