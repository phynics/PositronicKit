---
Priority: P0
Type: Cancellation / public API
Depends on: —
Blocks: PKRR-019, PKRR-023
Triage: ready-for-agent
Status: Done
Confidence: Confirmed (repository-wide symbol search)
Owner: Runtime
Effort: M
Tranche: A (lock terminal/execution invariants)
Review: PKR-002
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `d318dc7` (fast-forward to main). Added
`TimelineTaskRegistry` actor mapping `(timelineID, sendID) -> Task`. `ChatEngine.execute`
registers its stream-driving task and removes it on every terminal path via `defer`.
`TimelineDriver.cancel()` cancels the active send's task through the registry.
Eviction/deletion cancels and awaits bounded cleanup. Send-scoped handles ensure a stale
cancellation cannot terminate a newer send. 8 cancellation-invariant tests including the
no-op regression. 1394 tests in 211 suites pass on merged main.
---

# PKRR-002 — The advertised timeline cancellation API is disconnected from active chat tasks

## Summary
`TimelineDriver.cancel()` delegates to `TimelineManager.cancelGeneration(for:)`, but
the manager only cancels tasks previously stored by `registerTask` — and
`ChatEngine` creates its own task without ever registering it. The documented
cancellation path can be a no-op while streaming/tools/persistence/plugins continue.

## Current problem
- `Sources/PositronicKit/TimelineDriver.swift:35-38` — `TimelineDriver.cancel()`
  delegates to `TimelineManager.cancelGeneration(for:)`.
- `Sources/PositronicKit/Services/Timeline/TimelineManager.swift:259-270` — the
  manager only cancels tasks previously stored by `registerTask`.
- `Sources/PositronicKit/Services/Chat/ChatEngine.swift:197-202` — the chat engine
  creates its own task but never registers it with the timeline manager.
- `registerTask` has no production caller in repository-wide search (see also
  PKRR-028).

## Impact
Calling the documented cancellation method can be a no-op while provider streaming,
tools, persistence, and plugins continue. It also makes replacement-send
cancellation and lifecycle cleanup unreliable.

## Recommended change
Introduce a single `TimelineTaskRegistry` owned by the facade. Register the exact
task that drives each stream, remove it in `defer`, and cancel it from
`TimelineDriver.cancel`, eviction, deletion, and replacement sends. Prefer a
send-scoped handle so an old cancellation cannot terminate a newer send.

## Acceptance criteria
- [x] Regression test reproduces the no-op cancellation (cancel called, stream
  continues) before the fix.
- [x] A cancellation test proves the provider stream task receives cancellation.
- [x] Cancellation removes the registry entry on every terminal path.
- [x] Eviction/deletion cancels active work and waits for bounded cleanup.
- [x] A stale send ID cannot cancel a newer send.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit); add a cancellation-invariant suite. Public API change
— audit `Monad`/`Shuttle`/`Yakamoz` for cancellation usage and follow the
downstream-sync checklist.
