---
Priority: P1
Type: Persistence / idempotency
Depends on: PKRR-005
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Runtime + persistence
Effort: L
Tranche: B (persistence recoverable/idempotent)
Review: PKR-006
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `958acd7` (fast-forward to main).
Reordered `prepareSession` to defer `saveConversationSteps` until after history validation,
context gathering, workspace lookup, and prompt assembly all succeed. Added
`TurnIdempotencyGate` actor (in-memory `Set<UUID>`) rejecting duplicate sendIds with
`ChatEngineError.duplicateSendId` (error code 9006). Refactored
`ExternalToolOutputSubmissionGate` into validate/commit phases so failed batches are safely
resumable on retry. 5 idempotency-invariant tests with fault injection. 1445 tests in 217
suites pass on merged main.
---

# PKRR-006 — Turn input is persisted before preparation succeeds, and tool-output batches are not atomic

## Summary
User/tool input is saved before history validation, context, workspace lookup, and
prompt assembly. External tool outputs are reserved but persisted sequentially
without rollback. Preparation/store failures can leave orphan user messages and
ambiguous tool-output state.

## Current problem
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnPreparation.swift:44-59` —
  user/tool input is saved before history validation, context, workspace lookup, and
  prompt assembly.
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnPreparation.swift:284-345` —
  external tool outputs are reserved but persisted sequentially without rollback.

## Impact
Prompt assembly, history validation, or store failures can leave orphan user
messages. Retrying can duplicate inputs. If the Nth tool output fails to save,
earlier outputs remain while reservations are cleared, making recovery ambiguous.

## Recommended change
Use `sendId` as an idempotency key and introduce a persistence unit-of-work:
validate/prepare first where possible, then commit user input plus turn-start state
atomically. Add batch APIs for tool results or persist a resumable submission record
with per-item status.

## Acceptance criteria
- [x] Retrying the same `sendId` cannot duplicate user or tool messages.
- [x] A failed tool-output batch is either fully rolled back or safely resumable.
- [x] History validation failure leaves no new persisted input.
- [x] Regression tests reproduce the current orphan-input and partial-batch state
  before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit persistence + chat targets); add an idempotency-invariant
suite with fault injection. Coordinate with PKRR-005 (lifecycle contract) and
PKRR-016 (durable event ordering).
