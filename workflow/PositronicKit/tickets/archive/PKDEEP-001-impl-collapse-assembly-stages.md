# PKDEEP-001-impl — Collapse the 10 pass-through assembly stages into a direct section build

**Priority:** P2
**Type:** Implementation (deepening, promoted from PKDEEP-001 research)
**Depends on:** PKDEEP-001 (research)
**Blocks:** PKDEEP-007
**Status:** Done
**Resolution:** Deleted `PromptAssemblyStages.swift` (10 stage structs, 124 lines) and
`PromptAssembly.swift` (`PromptAssemblyEvent`/`PromptAssemblyContext` actor/`PromptAssemblyStage`
protocol, 104 lines). `PromptAssembler.assemble` now builds `[any Prompt]` directly via
`buildSections` with a `withLogging` helper for per-section timing logs. `overridePipeline` →
`customSections: (@Sendable () async -> [any Prompt])?` seam. Dead `assemblyPipeline` params
removed from `ChatEngine.execute` / `TurnPreparer.prepareSession`. `PromptHistoryOptimizer`
called directly. Duplicate-section-ID check preserved in both paths. Tests rewritten (5 in
`PromptAssemblyTests`, 3 in `StructuredCompressionIntegrationTests`); 2 context-actor tests
deleted. `make verify` green (898 tests / 157 suites). Net -285 lines. Commit `d457bd4`.

### Summary

Collapse the `PromptAssemblyStage` framework (10 stage structs, `PromptAssemblyContext` actor,
`PromptAssemblyEvent` enum, `Pipeline` usage) into one direct `[any Prompt]` build inside
`PromptAssembler.assemble`. The event stream has zero consumers, `overridePipeline` is test-only,
and all 10 stages are pure read-compose-append. See PKDEEP-001 for the full research report.

### Implementation

1. **Delete `PromptAssemblyStages.swift`** (124 lines) — all 10 stage structs.
2. **Delete `PromptAssembly.swift`** (104 lines) — `PromptAssemblyEvent`, `PromptAssemblyContext`
   actor, `PromptAssemblyStage` protocol + `process`/`running` extensions.
3. **Rewrite `PromptAssembler.assemble`** — replace `runPipeline` with a direct `buildSections`
   method that builds the `[any Prompt]` inline, preserving the exact section ordering:
   `SystemInstructions` → `AgentContext` (conditional) → `ContextNotes` → `Memories` → `Tools` →
   `WorkspacesContext` → `TimelineContext` (conditional) → `ChatHistory` (via
   `PromptHistoryOptimizer.optimizeForDefaultBudget`) → `UserQuery` → `extensionSections`.
4. **Add `withLogging` private helper** — replaces `Pipeline.runStage`'s start/complete/timing
   logs. Format: `"Starting prompt section: <id>"` / `"Completed prompt section: <id> in <dur>s"`.
5. **Replace `overridePipeline` with `customSections`** in `PromptAssemblyOptions`:
   ```swift
   var customSections: (@Sendable () async -> [any Prompt])? = nil
   ```
   When non-nil, the default build is skipped and this closure produces sections directly (matches
   today's `overridePipeline` semantics — full replacement, not interleaving).
6. **Remove dead `assemblyPipeline` params** from `ChatEngine.execute` and
   `TurnPreparer.prepareSession` (never non-nil in production). Keep `assemblyLogger`.
7. **Preserve duplicate-section-ID check** — the `duplicatePromptSectionIDs()` validation stays
   in `buildSections` (was in `runPipeline`).
8. **Delete `defaultAssemblyStages()`** — the ordering is now inline in `buildSections`.

### Files

- **Delete:** `Sources/PositronicKit/Services/Prompting/PromptAssemblyStages.swift`
- **Delete:** `Sources/PositronicKit/Services/Prompting/PromptAssembly.swift`
- **Modify:** `Sources/PositronicKit/Services/Prompting/PromptAssembler.swift` — new `buildSections` + `withLogging`; delete `runPipeline` + `defaultAssemblyStages`
- **Modify:** `Sources/PositronicKit/Services/Prompting/PromptAssemblyOptions.swift` — `overridePipeline` → `customSections`
- **Modify:** `Sources/PositronicKit/Services/Chat/ChatEngine.swift:164` — remove `assemblyPipeline` param
- **Modify:** `Sources/PositronicKit/Services/Chat/Stages/TurnPreparer.swift:35,119` — remove `assemblyPipeline` param + threading
- **NOT touched:** `Pipeline.swift`, `Pipeline+Logging.swift`, `PipelineTests.swift` (generic Pipeline survives for `ContextManager`)

### Test changes

- `Tests/PositronicKitTests/Services/PromptAssemblyTests.swift` (~25 deleted, ~99 rewritten):
  - Delete `contextHoldsProperties`, `contextAppendsSections` (test `PromptAssemblyContext` actor — goes away).
  - Rewrite `pipelineExecutesStages`, `promptBuilderUsesOverridePipeline`, `promptAssemblerEmitsVerboseLogs`, `promptBuilderRejectsDuplicateSectionIDs`, `promptAssemblerUsesOptionsObject` — replace `PromptAssemblyStage` conformances + `overridePipeline` with `customSections` closure.
  - Preserve `builderComposesSections`, `promptBuilderUsesPipeline`, `promptAssemblerReturnsRenderedPrompt`, `renderedPromptBuildsConversationMessages`, `renderedPromptProjectionsStayAligned` unchanged.
- `Tests/PositronicKitTests/StructuredCompressionIntegrationTests.swift` (~114 rewritten):
  - Replace each `struct Stage: PromptAssemblyStage { ... }` with a `customSections` closure. Compression assertions unchanged.
- `Tests/PKSharedTests/Utilities/PipelineTests.swift` + `PipelineErrorHandlingTests.swift` — **preserve unchanged** (generic Pipeline tests).

### Acceptance criteria

- [ ] `PromptAssemblyStages.swift` and `PromptAssembly.swift` deleted.
- [ ] `PromptAssembler.assemble` builds `[any Prompt]` directly via `buildSections`.
- [ ] `withLogging` helper preserves start/complete/timing log shape.
- [ ] `overridePipeline` → `customSections` seam; all tests rewritten.
- [ ] Dead `assemblyPipeline` params removed from `ChatEngine.execute` / `TurnPreparer.prepareSession`.
- [ ] `PromptHistoryOptimizer` called directly in `buildSections`.
- [ ] Duplicate-section-ID check preserved in `buildSections`.
- [ ] `make verify` green (test count should stay ~900, minus the ~25 deleted context-actor tests).
- [ ] CHANGELOG.md updated under `Unreleased`.
- [ ] No downstream consumer break (all affected types are internal; `ChatRunRequest` unchanged).

### Downstream sync

No public API touched. `PromptAssemblyOptions`, `PromptAssembler`, `ChatEngine`, `TurnPreparer` are
all internal. `ChatRunRequest` (public) is unchanged. Zero consumer source references to the six
symbols (confirmed by PKDEEP-001 grep). No downstream grep needed unless a later tranche removes
`PromptAssemblyStage` from a public extension surface.
