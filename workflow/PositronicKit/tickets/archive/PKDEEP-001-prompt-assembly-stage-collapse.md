# PKDEEP-001 — Deepen PromptAssembler by collapsing the 10 pass-through assembly stages

**Priority:** P2
**Type:** Research / architecture-review follow-up (deepening candidate, surfaced by `/improve-codebase-architecture`)
**Depends on:** none
**Blocks:** PKDEEP-007 (folded cleanup of `PromptAssemblyStage` hypothetical seam lands with this)
**Status:** Done (promoted → PKDEEP-001-impl)
**Resolution:** Research complete. Finding: **PROMOTE**. All 10 stages are pure read-compose-append
(zero I/O, zero side effects, zero plugin/TurnInspector interaction). The `PromptAssemblyEvent`
stream (`.stageStarted`/`.stageCompleted`) has **zero consumers** — `runPipeline` discards it via
`for try await _ in stream {}`. `overridePipeline` is **test-only** (the `assemblyPipeline` seam on
`ChatEngine.execute`/`TurnPreparer.prepareSession` is never non-nil in production; the public facade
`ChatRunRequest` doesn't expose it). `PromptHistoryOptimizer` survives as a direct call. A
per-section `withLogging` wrapper preserves all observability (timing + start/complete markers); the
event stream carries no structured metadata beyond the stage ID string. PKDEEP-006 can land
independently (different methods in `PromptAssembler.swift`, no data dependency). Implementation
ticket filed as PKDEEP-001-impl with the deepened shape documented (direct `[any Prompt]` build,
`overridePipeline` → `customSections: (@Sendable () async -> [any Prompt])?` seam, delete
`PromptAssemblyStages.swift` + `PromptAssembly.swift`, remove dead `assemblyPipeline` params from
`ChatEngine.execute`/`TurnPreparer.prepareSession`). Test churn: ~25 deleted, ~213 rewritten
(mechanical), ~566 preserved.

### Summary

`PositronicKit/Services/Prompting/` carries a stage framework — `PromptAssemblyStage`
protocol, `PromptAssemblyContext` actor, `PromptAssemblyEvent` enum, a generic `Pipeline`
runner — whose only payload is ten structurally identical stage structs that each read one
field off `LLMPromptRequest`, wrap it in a section type, and `await context.append(...)`.
The pipeline's own event stream (`.stageStarted` / `.stageCompleted`) is consumed and
immediately discarded inside `PromptAssembler.runPipeline` (`PromptAssembler.swift:131`);
no caller outside the assembler reads it. The candidate is to collapse this into one
deep `PromptAssembler.assemble` method that builds the `[any Prompt]` directly, treating
custom stage ordering (today's `overridePipeline` parameter, used only in tests) as a
list-of-factories seam rather than a framework-shaped seam.

This ticket is **research**, not implementation: it scopes the constraints, dependencies,
and test-surface impact of the deepening, and either promotes the candidate to an
implementation ticket or rejects it with a load-bearing reason (optionally recorded as
an ADR).

### Current problem (with file:line references)

- `Sources/PositronicKit/Services/Prompting/PromptAssemblyStages.swift:1-124` — ten stage
  structs (`SystemInstructionsStage`, `AgentContextStage`, `ContextNotesStage`,
  `MemoriesStage`, `ToolsStage`, `WorkspacesContextStage`, `TimelineContextStage`,
  `ChatHistoryStage`, `UserQueryStage`, `ExtensionSectionsStage`) each 4–9 lines,
  structurally identical: read a field off `context.request`, wrap, append.
- `Sources/PositronicKit/Services/Prompting/PromptAssembly.swift:6-13` — `PromptAssemblyEvent`
  enum (`.stageStarted(String)`, `.stageCompleted(String)`) only ever consumed by the
  assembler's own `for try await _ in stream {}` loop.
- `Sources/PositronicKit/Services/Prompting/PromptAssembly.swift:17-58` — `PromptAssemblyContext`
  actor holds `request`, `agentInstance`, `timeline`, `extensionSections` and accumulates
  `sections: [any Prompt]`; every `append` is an actor hop.
- `Sources/PositronicKit/Services/Prompting/PromptAssembly.swift:62-103` — `PromptAssemblyStage`
  protocol + default `process`/`running` impls that yield start/complete events into an
  `AsyncThrowingStream` and `finish()` it; the events are not observable outside the
  pipeline runner.
- `Sources/PositronicKit/Services/Prompting/PromptAssembler.swift:17-30` —
  `defaultAssemblyStages()` returns the ten stages as `[any PipelineStage<...>]`; this is
  the only ordering definition and survives without the framework.
- `Sources/PositronicKit/Services/Prompting/PromptAssembler.swift:118-141` — `runPipeline`:
  builds the `Pipeline`, calls `pipeline.execute(context)`, then `for try await _ in
  stream {}` discards every event, then reads `await context.sections` back out. The
  framework is talking to itself.

**Deletion test result:** complexity vanishes. The ten stages and the framework collapse
to an `[any Prompt]` literal built top-to-bottom in `PromptAssembler.assemble`. The only
piece carrying independent value is per-stage logging (`basePipeline.withLogger(logger)`
at `PromptAssembler.swift:124-128`), which a single `withLogging` helper preserves.

### Research scope

1. **Confirm the event-stream claim empirically.** Grep the entire workspace (PositronicKit
   + Monad + Shuttle + Yakamoz) for any consumer of `PromptAssemblyEvent`,
   `.stageStarted`, `.stageCompleted`, `PromptAssemblyStage` (the protocol), or
   `PromptAssemblyContext` outside `PromptAssembler.swift` /
   `PromptAssemblyStages.swift` / their tests. Expected: zero, but verify. Record the
   grep results in the ticket resolution.
2. **Audit `overridePipeline` / `PromptAssemblyOptions.overridePipeline` usage.**
   `PromptAssembler.swift:82` threads `options.overridePipeline` through `runPipeline`.
   Find every call site (PositronicKit + consumers). Expected: only tests. If a real
   downstream caller depends on it, the list-of-factories seam must preserve that
   capability — document the shape.
3. **Survey the existing tests** that touch assembly stages:
   `Tests/PositronicKitTests/...PromptAssembler*`, `...PromptAssembly*`,
   `...PromptAssemblyStage*`. Identify which tests would be deleted (stage-.stub tests)
   and which would be rewritten to assert `assemble(request)` output directly. Estimate
   the test churn in lines.
4. **Confirm `PromptHistoryOptimizer` (used by `ChatHistoryStage`) survives the collapse.**
   It is a real pure helper called by the stage; in the deepened assembler it becomes a
   direct call. No change in semantics expected.
5. **Pass-through budget check.** Confirm no stage does anything *other* than read-compose-append
   that the deletion test assumes. Specifically check whether any stage mutates shared
   state on the context beyond `append`, performs async I/O, or registers side effects
   with `TurnInspector` / plugins. If a stage does (suspect: `ExtensionSectionsStage`
   ordering relative to plugin-injected sections), call it out — the deepening may need
   to preserve a sub-shape.
6. **Logging shape.** Decide in the deepening: does `withLogging("SystemInstructions")
   { SystemInstructions(...) }` per section constructor preserve enough observability,
   or does the existing `.stageStarted`/`.stageCompleted` event stream carry value
   (e.g. structured log fields) that the simple wrapper loses? If yes, record what.
7. **Boundary with PKDEEP-006 (Candidate 06 — one-caller prompting helpers).** The
   `RenderedPromptProjection` / `RenderedPrompt+Messages` / `StructuredPromptMetadata`
   helpers live in the same directory; the deepening of C01 is the natural moment to
   fold them. Confirm whether C01 can land cleanly without C06, or whether the two
   should be ticketed as a single implementation ticket.

### Acceptance criteria

- [ ] Workspace-wide grep results for `PromptAssemblyEvent`, `PromptAssemblyStage`,
      `PromptAssemblyContext`, `overridePipeline` recorded; non-test external usage
      identified or confirmed absent.
- [ ] Test churn estimate (lines deleted / rewritten) for `Tests/PositronicKitTests/`
      assembly tests produced.
- [ ] Per-stage audit table: stage name → "anything beyond read-compose-append" (Y/N +
      note). Flags any stage that needs preservation.
- [ ] Logging-shape decision recorded: per-section `withLogging` is sufficient **or**
      the event stream carries value that must survive (specify what).
- [ ] Pairing recommendation vs PKDEEP-006: "land C01 alone" **or** "merge C01+C06 into
      one implementation ticket" with rationale.
- [ ] Final finding: **promote** (file `PKDEEP-001-impl` implementation ticket with the
      deepened shape documented) **or reject** (state the load-bearing reason; if it
      would be re-suggested by a future architecture review, offer an ADR).
- [ ] If rejected, ticket closes with `Triage: wontfix` and resolution note; optionally
      ADR drafted at `docs/adr/`.
- [ ] If promoted, this ticket moves to `archive/` once the implementation ticket is
      filed; the implementation ticket references this research ticket as its origin.

### Downstream sync

No public API touched by this research; implementation may touch package-internal surface
only (the deletion is private). If the implementation tranche later removes
`PromptAssemblyStage` from any public extension surface, grep all three consumers
(Monad, Shuttle, Yakamoz) for stage conformances at that point.