---
Priority: P1
Type: Event contract / ergonomics
Depends on: PKRR-003
Blocks: PKRR-019
Triage: ready-for-agent
Status: Done
Confidence: Confirmed (symbol search + control flow)
Owner: Public API
Effort: M
Tranche: C (cross-platform generation + public contracts)
Review: PKR-011
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `9504242` (fast-forward to main). Added
`.maxTurnsReached` and `.deferredForExternalTool` terminal states to `CompletionEvent`.
Max-turn exhaustion now emits a distinct terminal event instead of silently finishing.
Deferred external tool path emits its own terminal event. Deprecated orphan cases
(`.meta(.generationCompleted)` and `.completion(.streamCompleted)`) retained for Codable
compatibility. Updated `docs/Usage.md` with correct event names and new terminal cases.
6 terminal-event-uniqueness tests. Additive/deprecation — backward-compatible. 1471 tests
in 220 suites pass on merged main.
---

# PKRR-011 — Documented terminal events are not emitted consistently, and max-turn exhaustion looks successful

## Summary
`ChatEvent` defines both meta and completion `generationCompleted`, plus
`streamCompleted`. Production emits the completion variant, not the meta one. Max-turn
exhaustion only logs and finishes the stream, so it looks successful. The usage guide
tells consumers to handle the meta completion and `streamCompleted`. Consumers cannot
reliably distinguish normal completion, max-turn exhaustion, deferred external tool
work, cancellation, and failure by a single terminal event.

## Current problem
- `Sources/PKShared/SharedTypes/ChatEvent.swift:122-163` — the API defines both meta
  and completion `generationCompleted`, plus `streamCompleted`.
- `Sources/PositronicKit/Services/Chat/Stages/MessagePersistenceStage.swift:46-67` —
  production emits the completion `generationCompleted`, not the meta variant.
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnLoop.swift:117-125` — max-turn
  exhaustion only logs and finishes the stream.
- `docs/Usage.md:134-167` — the guide tells consumers to handle meta completion and
  `streamCompleted`.

## Impact
Consumers cannot reliably distinguish normal completion, max-turn exhaustion,
deferred external tool work, cancellation, and failure by a single terminal event.
Exhaustive switches carry apparently dead cases (see also PKRR-028).

## Recommended change
Define exactly one terminal-state enum and guarantee exactly one terminal event
before stream closure. Remove/deprecate orphan cases or start emitting them
intentionally. Include `maxTurnsReached` and `deferredForExternalTool` terminal
states.

## Acceptance criteria
- [x] Every execution path emits exactly one terminal state.
- [x] No terminal case is definition/tests/docs-only.
- [x] Max-turn exhaustion emits a distinct terminal state, not a success.
- [x] Docs compile against the current enum names and production behavior
  (relates to PKRR-027).
- [x] Regression tests reproduce the current inconsistent emission before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PKShared + PositronicKit); add a terminal-event-uniqueness suite.
Public API change — audit `Monad`/`Shuttle`/`Yakamoz` `ChatEvent` switches and
follow the downstream-sync checklist. Coordinate with PKRR-003 and PKRR-028.
