---
status: accepted
---

# Memory retrieval and prompt boundaries

## Context

The v4 convergence work needs an explicit boundary for automatic memory retrieval and for the
small prompt and diagnostic helpers that were left behind by the former context pipeline. Issue
#90 required a downstream audit before removing or replacing those seams.

The audit covered the current PositronicKit tree and the maintained downstream trees available on
2026-08-24:

| Consumer | Revision or dependency | Result |
| --- | --- | --- |
| Gnostic | `main` at `9c94404`; `Package.resolved` pins PositronicKit `4.0.0` at `50fc19d` | `Sources/GnosticCore/Adapters/PositronicAscendantAdapter.swift` owns in-memory Agent, Thread, message, Workspace, and tool stores, then runs Turns through Thread handles. It has no call site for the legacy retrieval path, prompt primitive namespace, or transient debug-result mutator. |
| Yakamoz | `main` at `5d9b9af`; `project.yml` declares PositronicKit from `2.0.0` and commits no `Package.resolved` | `Sources/YakamozCore/Prompting/CurrentTimeSectionProvider.swift` uses public `PromptSectionProviding`, `PromptBuildContext`, and `TextPrompt`; `Sources/YakamozCore/Models/PersistenceModels.swift` and the workspace runtime represent continuity as Agent template and Workspace data. The source has no call site for the legacy retrieval path, prompt primitive namespace, or transient debug-result mutator. The dependency declaration is not a reproducible v4 pin and requires a separate consumer migration. |

The former automatic `MemoryRetrievalStage` implementation and `MemoryStoreProtocol` store
contract were removed from the v4 working tree by the legacy context-pipeline cut (`da58a1c`).
The empty package-internal `PromptPrimitives` namespace and the transient `addDebugToolResult`
buffer were removed by the Workspace-filesystem change (`5c1061b`). The released `4.0.0` API
artifacts still contain the older memory store contract, so this is a breaking boundary for a
future v4 release rather than a claim that the tagged release never shipped it.

The current source-level seams are:

- `Sources/PositronicKit/Models/Agents/AgentContext.swift` owns `AgentContextSource`, the
  filesystem-backed default, and typed continuity values.
- `Sources/PositronicKit/Customization/RuntimeCustomization.swift` owns bounded
  `TurnContextSource` contributions.
- `Sources/PKPrompt/PromptBuilder/Builder/Node/PromptPrimitive.swift` owns package-internal leaf
  lowering; public prompt authors use the concrete `Prompt` values in `Sources/PKPrompt/PromptBuilder`.
- `Sources/PositronicKit/Services/Turn/Stages/MessagePersistenceStage.swift` projects durable
  runtime tool intents and results into diagnostic snapshots; it does not read a transient debug
  result buffer.
- `Sources/PositronicKit/Services/Storage/InMemory*.swift` supplies the supported in-process
  convenience stores used by examples, tests, and prototyping.

## Decisions

1. PositronicKit does not restore or replace the automatic retrieval stage with a new global memory
   pipeline. Semantic or vector retrieval remains outside the current package surface until a
   separately owned contract has a concrete consumer and persistence story.
2. Managed Agent continuity enters through `AgentContextSource` and its typed
   `AgentContextSnapshot`. `DefaultAgentContextSource` provides filesystem-backed `SOUL.md`
   instructions and a bounded `Notes/` catalog; hosts with database, remote, hybrid, or no-memory
   continuity inject their own source. `AgentContextMemory` is the bounded value for a source that
   has already performed retrieval.
3. Per-Turn host additions use the bounded, namespaced `TurnContextSource`. This is additive
   context, not a replacement for Agent continuity and not permission to register pipeline stages.
   Full note contents remain host Workspace data and are read on demand through Workspace file
   tools.
4. `PKPrompt` keeps its package-internal primitive leaf machinery because assembly, compression,
   and journaling use it. Consumers use public `Prompt` values such as `TextPrompt` and
   `HistoryPrompt`; the removed namespace is not replaced with a public primitive registry.
5. Tool diagnostics are derived from durable Thread runtime tool intents and results and projected
   into `TurnSnapshot`. Prompt assembly diagnostics use the opt-in `swift-log` logger. A transient
   per-Turn debug-result buffer is not a supported integration seam.
6. In-memory stores remain supported defaults, examples, and test conveniences for the active
   Thread, Agent, message, Workspace, tool, request-origin, and runtime-repository contracts. This
   does not revive the removed automatic memory store.

## Migration boundary

Downstream consumers that need continuity should migrate to `AgentContextSource`,
`TurnContextSource`, or Workspace file tools according to whether the data is Agent-scoped,
Turn-scoped, or model-directed. A future retrieval product must define its own result value,
ranking and budget policy, durability boundary, and consumer before it can become a PositronicKit
contract. No compatibility alias is warranted by the current Gnostic or Yakamoz audit.
