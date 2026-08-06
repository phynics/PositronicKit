---
Priority: P1
Type: Tool persistence / event ordering
Depends on: PKRR-006
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Tool runtime
Effort: S
Tranche: B (persistence recoverable/idempotent)
Review: PKR-016
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `335e740` (fast-forward to main).
Reordered `ToolRouter.projectOutcome/projectError` to call `messageStore.saveMessage`
before `continuation.yield`. Persistence failures emit `.persistenceFailed` terminal
status instead of `.success`/`.failed`. Added `ToolExecutionStatus.persistenceFailed`
case to `ChatEvent`. 4 tool-durability-ordering tests including mixed-batch scenario.
1449 tests in 218 suites pass on merged main.
---

# PKRR-016 — Tool success/failure is emitted before the corresponding tool message is durable

## Summary
`ToolRouter` yields the completion status before `messageStore.saveMessage`. The
UI/model can observe success, then the turn throws because persistence failed, and
conversation history lacks the result — making a later retry unsafe and tool-call
pairing invalid.

## Current problem
- `Sources/PositronicKit/Services/Tools/ToolRouter.swift:426-477` — the
  continuation yields completion status before `messageStore.saveMessage`.

## Impact
The UI/model can observe success, then the turn throws because persistence failed.
Conversation history lacks the result, making a later retry unsafe and tool-call
pairing invalid.

## Recommended change
Persist first, then emit durable success/failure. If low-latency progress is needed,
use a nonterminal `executedAwaitingPersistence` event. Include a
`persistenceFailed` terminal state.

## Acceptance criteria
- [x] A store failure never emits terminal tool success.
- [x] Persisted history and emitted terminal status are always consistent.
- [x] Regression test reproduces the current emit-before-durable ordering before
  the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit tool targets); add a tool-durability-ordering suite.
Coordinate with PKRR-006 (idempotent persistence) and PKRR-011 (terminal event
contract).
