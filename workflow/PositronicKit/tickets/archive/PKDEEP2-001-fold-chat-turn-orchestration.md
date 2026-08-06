# PKDEEP2-001 — Fold TurnPreparer and TurnLoopController back into ChatEngine

**Priority:** P3
**Type:** Refactor (deepening; internal only — no public API change)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `336f756`) — folded `TurnPreparer` into
`ChatEngine+TurnPreparation.swift` and `TurnLoopController` into `ChatEngine+TurnLoop.swift` as
`private extension ChatEngine` files (PKDEEP-002 `TimelineManager` pattern); deleted both helper
structs. `ChatEngine.execute` now calls `prepareSession`/`runChatLoop` directly.
`ExternalToolOutputSubmissionGate` remains a single shared file-scope actor.
`PromptSnapshotBuilder`/`PartialAssistantPersistence` kept standalone. All Phase-4 `LogKeys`
metadata + `wrapForeignError` preserved in the fold (logs now emit under `chat-engine`).
`TurnLoopControllerTests`: 2 cases recast at execute level (`pluginFollowUpResumesLoop`,
`loopStopsAtMaxTurns`), 3 deleted as duplicates of `ChatEngineFailurePersistenceTests`/
`ChatEngineTests` (no assertion lost). No public API change. `make verify` green (923 tests / 158
suites).

### Summary

The PKARCH-001 split (2026-07-06) left the chat-turn path spread across five modules
(1,008 lines) with single-caller helpers whose interfaces mirror their implementations —
the same shallow-helper pattern PKDEEP-003 folded out of `ToolRouter` one day after
PKARCH-002 created it. Fold `TurnPreparer` (346 L, one production caller) and
`TurnLoopController` (264 L, one production caller) back into `ChatEngine` as extension
files, following the PKDEEP-002 `TimelineManager` pattern. Keep `PromptSnapshotBuilder`
and `PartialAssistantPersistence` as standalone internal helpers with their existing
isolation tests — they are the genuinely separable pieces (pure, no marshalled state).

**Conflict note:** this re-litigates PKARCH-001 ("deepened ChatEngine into a thin
coordinator"). Precedent: PKDEEP-003 re-litigated the same-vintage PKARCH-002 split for
identical friction. Surfaced by `/improve-codebase-architecture` on 2026-07-08 (second
pass); investigation verified all claims below by direct read + grep.

### Current Problem (with file:line references)

All five types are `internal` (verified — no `public`/`package` modifier), have **zero**
references in Monad, Shuttle, Yakamoz, or `PositronicKitExamples`, so this is a pure
internal refactor.

- `Sources/PositronicKit/Services/Chat/ChatEngine.swift` (216 L) — `struct ChatEngine`
  is now argument-marshalling glue. `execute(...)` (L149–165, 15 parameters) passes
  **every one of its parameters straight through** to
  `TurnPreparer(dependencies:logger:).prepareSession(...)` at L175–178, then constructs
  `PromptSnapshotBuilder(logger:)` (L196), `PartialAssistantPersistence(messageStore:logger:)`
  (L197–200), and `TurnLoopController(dependencies:logger:additionalStages:snapshotBuilder:partialPersistence:)`
  (L201–207) — all from its own stored state (`dependencies`, `logger`, `additionalStages`).
  Nothing constructed at these sites depends on the returned `ChatTurnContext`.
- `Sources/PositronicKit/Services/Chat/TurnPreparer.swift` (346 L) — `struct TurnPreparer`
  (L14): stored `dependencies: ChatEngine.Dependencies` + `logger` (L15–16). One method,
  `prepareSession(...)` (L20–36), whose 15-parameter signature duplicates `execute(...)`
  parameter-for-parameter. **One production caller** (ChatEngine.swift:175). Private
  helpers `saveConversationSteps` (L192), `fetchContext` (L215), `validateToolHistory`
  (L242); private static `ExternalToolOutputSubmissionGate` actor (L275, referenced via
  static let at L213) and `ReservedToolOutput` (L343).
- `Sources/PositronicKit/Services/Chat/TurnLoopController.swift` (264 L) —
  `struct TurnLoopController` (L14): stored fields are ChatEngine's own state re-injected
  (`dependencies`, `logger`, `additionalStages`) plus the two helpers. One entry method
  `runChatLoop(continuation:context:)` (L30–33). **One production caller**
  (ChatEngine.swift:201) plus direct construction in `TurnLoopControllerTests.swift:58`.
  Constructed fresh per `execute()` call; carries no cross-call state.
- The interface of each helper is as complex as its implementation (shallow): learning
  `prepareSession`'s signature = learning `execute`'s; tracing one turn crosses 5 files.

**Deletion test:** deleting `TurnPreparer`/`TurnLoopController` concentrates the turn
logic in one module and removes the 15-parameter marshalling relay entirely — complexity
concentrates, it does not relocate.

### Implementation Requirements

1. **Fold using the PKDEEP-002 extension-file pattern** (see
   `TimelineManager.swift` + `TimelineManager+Lifecycle.swift` + `TimelineManager+Attachments.swift`):
   - `ChatEngine+TurnPreparation.swift` — absorb `TurnPreparer` as
     `private extension ChatEngine` methods (`prepareSession` becomes a private method
     reading `self.dependencies`/`self.logger`; drop the now-redundant init threading).
     `ExternalToolOutputSubmissionGate` + `ReservedToolOutput` become file-scope `private`
     declarations in this file (the gate stays a **static/shared** actor — it is a
     process-wide idempotency guard, not per-engine state; keep it as a
     `private static let` on `ChatEngine` or file-scope `private let`).
   - `ChatEngine+TurnLoop.swift` — absorb `TurnLoopController` as `private extension
     ChatEngine`. `LoopContinuation` (currently private nested enum, L23–26) becomes a
     file-scope `private enum`. `additionalStages` is read directly from `self` (removes
     one init parameter). `PromptSnapshotBuilder`/`PartialAssistantPersistence` are
     constructed as locals where needed, exactly as today.
   - Delete `TurnPreparer.swift` and `TurnLoopController.swift`.
2. **Keep unchanged:** `PromptSnapshotBuilder.swift` (126 L), `PartialAssistantPersistence.swift`
   (56 L), `ChatTurnContext.swift`, `ChatTurnFollowUpPolicy.swift`, `ChatTurnPipelineBuilder.swift`,
   `ChatEngine.Constants` (`.sentinelToolName`, `.maxRemoteDepth` — referenced by
   `ToolCallExtractionStage` and `TimelineSendTool.swift:75–78`).
3. **Must-not-regress paths** (name these in tests / review):
   - **PKR-10** incremental follow-up snapshot: `PromptSnapshotBuilder.synthesizeFollowUpPrompt`
     (L38–83, O(n²)-avoidance comment L67–71), called from the loop at (old)
     TurnLoopController.swift:84–88 and :111–117, plus
     `promptHistory.append(messageCount:estimatedTokens:)` at :106–109.
   - **STAB-1** partial-assistant persistence: `.cancelled` path (old :147), error path
     (old :159), `isCancellationOrigin(_:)` unwrapping `PipelineError.stageFailed`/
     `.cleanupFailed` (old :168–179), `.generationCancelled()` yielded before
     `continuation.finish()` (old :148–149).
   - **Plugin continuation:** `ChatTurnFollowUpPolicy.pluginMessages` (ChatTurnFollowUpPolicy.swift:17–43)
     called at (old) :69–75; `shouldContinueWithPluginMessages` gating (old :78–82);
     `priorOutput` accumulation (old :59–63).
   - **Turn inspection:** `publishTurnInspectionIfNeeded` (old :231–263) — uses
     `promptHistory?.nextInspectionTurnIndex()`, **not** `turnCount` (row-collision
     comment old :240–244).
   - **Sidecar wiring:** `effectiveSystemInstructions` / `sidecarTurnInstructions`
     (TurnPreparer.swift:43–49, fed into `LLMPromptRequest.turnInstructions` at :94);
     sidecar validation stays in `execute` (ChatEngine.swift:170–173).
   - **Remote depth:** computed at TurnPreparer.swift:58 → `ChatTurnContext.remoteDepth`.
4. **Test churn:**
   - `TurnLoopControllerTests.swift` (251 L, Swift Testing, 5 cases): all five are already
     covered or trivially recastable at the `ChatEngine.execute` level —
     `cancellationPersistsCancelledAssistant` / `failurePersistsPartialAssistant` /
     `emptyFailureSkipsPersistence` duplicate `ChatEngineFailurePersistenceTests`
     (:129, :85, :204 respectively); `loopStopsAtMaxTurns` duplicates
     `ChatEngineTests` "maxTurns limits the generation loop" (:725);
     `pluginFollowUpResumesLoop` recasts via `Dependencies.chatTurnPlugins`.
     Recast `pluginFollowUpResumesLoop` (and `loopStopsAtMaxTurns` if not exactly
     duplicated) at `execute` level; delete the redundant three. Coverage delta must be
     non-negative — verify each assertion exists at execute level before deleting.
   - `PromptSnapshotBuilderTests.swift` (151 L): zero churn (type unchanged).
   - `ChatEngineTests` (1,302 L), `ChatEnginePipelineTests` (663 L),
     `ChatEngineFailurePersistenceTests` (232 L): unchanged — they already cross the
     surviving seam.
5. No `Sendable` annotations needed (all folded types are structs of Sendable `let`s;
   verified). No changes to `PositronicKit.swift` facade (`addStage` keeps its
   `PipelineStage<ChatTurnContext, ChatEvent>` signature).
6. Update `CHANGELOG.md` under `Unreleased` → `Changed` (internal refactor note).

### Acceptance Criteria

- [ ] `TurnPreparer.swift` and `TurnLoopController.swift` deleted; logic lives in
      `ChatEngine+TurnPreparation.swift` / `ChatEngine+TurnLoop.swift` as private extensions.
- [ ] `PromptSnapshotBuilder` and `PartialAssistantPersistence` unchanged, with their
      isolation tests intact.
- [ ] `ExternalToolOutputSubmissionGate` remains a single shared (static) actor instance.
- [ ] All must-not-regress paths in requirement 3 exercised by surviving tests
      (name them in the resolution note).
- [ ] `TurnLoopControllerTests` cases recast at `execute` level or verified duplicated;
      no assertion lost.
- [ ] `make verify` green with a non-decreasing executed-test count relative to the
      880-tests / 155-suites baseline minus deliberately-deleted duplicates (check the
      count actually ran — zero-test green is a known trap).
- [ ] No public API change (all touched types were and remain `internal`).
- [ ] `CHANGELOG.md` `Unreleased` updated.
