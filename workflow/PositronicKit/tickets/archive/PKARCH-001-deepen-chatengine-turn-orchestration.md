# PKARCH-001: Deepen the ChatEngine turn-orchestration module

**Priority:** P2
**Type:** Internal refactor (no public API change; ChatEngine is a package-internal runtime module)
**Depends on:** PKARCH-004 (narrow LLM seam; the ChatEngine split is easier to test once the LLM mock surface is smaller)
**Blocks:** None
**Triage:** ready-for-agent

### Summary

`ChatEngine` is the runtime's turn-orchestration module. It currently mixes the ReAct loop, turn preparation, post-turn plugin follow-up, partial-assistant persistence on cancellation/failure, and follow-up prompt synthesis into two files (`ChatEngine.swift` and `ChatEngine+ContextBuilding.swift`). This ticket deepens the module by splitting those concerns into narrow modules behind the existing `ChatEngine` seam.

### Current Problem

- `ChatEngine.execute(...)` has 18 parameters and ~930 lines of implementation across two files.
- A single turn requires reading loop control (`runChatLoop`), session preparation (`prepareSession`), plugin follow-up (`ChatTurnFollowUpPolicy`), partial persistence (`persistPartialAssistantIfNeeded`), and follow-up prompt synthesis (`synthesizeFollowUpPrompt`).
- Tests of the loop must bring up the full ChatEngine with a TimelineManager, ToolRouter, message store, and mock LLM.
- The deletion test fails: deleting ChatEngine would scatter loop policy, persistence, and prompt synthesis across callers.

### Implementation Requirements

1. Introduce focused internal modules behind the existing ChatEngine seam:
   - `TurnLoopController` — owns the ReAct continuation loop, max-turns, and cancellation handling.
   - `TurnPreparer` — owns `prepareSession`: save inputs, gather context, resolve workspaces/agent/origin, build the initial prompt via `PromptAssembler`, and record the prompt snapshot.
   - `ChatTurnFollowUpPolicy` — already exists as a nested helper; lift it to a top-level module with a narrow interface (`pluginMessages(for:turnCount:accumulatedOutput:plugins:logger:)` and `shouldContinue(...)`).
   - `PromptSnapshotBuilder` — owns `synthesizeFollowUpPrompt` and the incremental-string assembly that avoids O(n²) re-rendering.
   - `PartialAssistantPersistence` — owns the STAB-1 partial/cancelled assistant persistence logic, mirroring `MessagePersistenceStage`.
2. `ChatEngine` becomes a thin coordinator: validate preconditions, ask `TurnPreparer` for the initial context, hand the loop to `TurnLoopController`, and stream results.
3. Keep all existing package/internal access levels; do not change the public `PositronicKit.run(...)` seam.
4. Preserve the current behavior for: cancellation, partial persistence, plugin follow-up, sidecar validation, and prompt-history journal-diff continuity.

### Acceptance Criteria

- [ ] `ChatEngine.swift` is reduced to a thin coordinator; the five extracted modules live in their own files.
- [ ] Each extracted module has a small interface that can be tested in isolation.
- [ ] `TurnLoopController` tests exercise max-turns, cancellation, and continuation without a full ChatEngine setup.
- [ ] `PromptSnapshotBuilder` tests verify the incremental-string path matches full re-assembly.
- [x] Existing `ChatEngineTests` still pass after the split; no behavioral regression.
- [x] `make verify` green.

## Resolution

**Status:** Done (commit pending)
**Gate:** `make verify` green — 810 tests / 149 suites.
**Approach:** `ChatEngine.swift` reduced from 537 to 218 lines (thin coordinator: precondition
validation, `TurnPreparer` delegation, `TurnLoopController` hand-off). Four focused modules
extracted to their own files under `Sources/PositronicKit/Services/Chat/`:
`TurnLoopController` (ReAct loop, max-turns, cancellation + `LoopContinuation`),
`TurnPreparer` (`prepareSession`, `saveConversationSteps`, `fetchContext`, `validateToolHistory`,
`ExternalToolOutputSubmissionGate` — content split out of the deleted
`ChatEngine+ContextBuilding.swift`), `PromptSnapshotBuilder` (`synthesizeFollowUpPrompt` +
`buildFollowUpSnapshot` + `makeHistoryMessage`, PKR-10 incremental-string path preserved),
`PartialAssistantPersistence` (STAB-1 partial/cancelled persistence). `ChatTurnFollowUpPolicy`
was already a top-level type with the narrow interface the ticket asked for — verified, no change
needed. `ChatEngineError` moved from the deleted `+ContextBuilding` file into `ChatEngine.swift`.
Behavior preserved for cancellation, partial persistence, plugin follow-up, sidecar validation,
and prompt-history journal-diff continuity. Landed against the PKARCH-004 narrowed `LLMStreamClient`
seam (ChatEngine no longer depends on the full `LLMServiceProtocol`).
**Tests added:** `TurnLoopControllerTests` (5 tests — max-turns, cancellation→`.cancelled`,
failure→`.partial`, plugin continuation, empty-failure threshold; drives `runChatLoop` directly
without `ChatEngine.execute`/`TurnPreparer`), `PromptSnapshotBuilderTests` (4 tests — incremental
path matches full re-assembly over 3 batches, empty-batch, promptHistory threading,
empty-base-section).
