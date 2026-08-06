---
Priority: P0
Type: Failure handling / orchestration
Depends on: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Runtime
Effort: S
Tranche: A (lock terminal/execution invariants)
Review: PKR-003
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `ad73609`. Binary `.stop`/`.continueWith`
loop signal replaced with typed `.completed`/`.continueWith`/`.failed`/`.cancelled`; only
`.completed` runs `ChatTurnFollowUpPolicy`. 5 terminal-invariant tests prove no
plugin/message/LLM activity after provider failure, cancellation, or pipeline-stage failure.
1369 tests in 208 suites pass on merged main.
---

# PKRR-003 — A failed turn can continue into plugin follow-up work after the stream has already failed

## Summary
The turn loop treats cancellation and error completion as `.stop`, which the outer
loop reads as normal completion and uses to run `ChatTurnFollowUpPolicy`. After
consumers receive a terminal failure/cancellation, the runtime may still invoke
plugins, append messages, build snapshots, or start another LLM turn.

## Current problem
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnLoop.swift:63-96` — the outer
  loop treats `.stop` as a normal completion and runs `ChatTurnFollowUpPolicy`.
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnLoop.swift:149-172` — both
  cancellation and error handlers finish the continuation and return `.stop`.

## Impact
After consumers receive cancellation or a thrown stream error, the runtime may still
invoke plugins, append messages, build snapshots, and potentially make another LLM
turn. This creates hidden cost, state mutation after terminal delivery, and
hard-to-reproduce races.

## Recommended change
Replace the binary loop signal with terminal outcomes such as `.completed`,
`.failed(Error)`, `.cancelled`, and `.continueWith`. Only `.completed` may run
plugin follow-up policy. Make stream finalization occur at one orchestration
boundary.

## Acceptance criteria
- [x] Regression tests cover failure and cancellation during streaming and during a
  pipeline stage, proving post-terminal plugin/message/prompt-history activity
  before the fix.
- [x] No plugin executes after provider failure or cancellation.
- [x] No message, prompt-history, or LLM activity occurs after terminal delivery.
- [x] Exactly one terminal stream state is emitted per turn (relates to PKRR-011).
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit); add a terminal-invariant suite.
