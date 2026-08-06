---
Priority: P1
Type: One-shot API
Depends on: PKRR-002, PKRR-011
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Public API
Effort: M
Tranche: C (cross-platform generation + public contracts)
Review: PKR-019
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `bbd6fc7` (merged in `ecd0b63`). Added
`OneShotResult` with content, usage, finish reason, ID, and model; per-call generation
parameters; shared idle-timeout/cancellation runner with timeline streaming. Added stalled
stream and cancellation regression tests. 1503 tests in 222 suites pass on merged main.
---

# PKRR-019 — One-shot streaming has weaker timeout, observability, and parameter ergonomics than timeline chat

## Summary
One-shot streaming directly forwards provider chunks with no idle watchdog, and
per-call parameters/metadata are not exposed. Timeline chat has a 60-second idle
timeout. A stalled one-shot request can hang indefinitely while the analogous chat
request times out, and callers cannot request per-call sampling/output limits or
receive usage/finish metadata.

## Current problem
- `Sources/PositronicKit/PositronicKit+OneShot.swift:7-67` — one-shot streaming
  directly forwards provider chunks with no idle watchdog; per-call parameters and
  metadata are not exposed.
- `Sources/PositronicKit/Services/Chat/ChatEngine.swift:78-82` — timeline chat has a
  60-second idle timeout.

## Impact
A stalled one-shot request can hang indefinitely while the analogous chat request
times out. Callers cannot request per-call sampling/output limits or receive
usage/finish metadata. String accumulation with repeated `+=` can be costly for
large output.

## Recommended change
Unify both tiers around a shared generation runner with cancellation, idle timeout,
usage, and structured terminal result. Add per-call options and assemble chunks with
an efficient buffer.

## Acceptance criteria
- [x] One-shot and timeline APIs share timeout/cancellation tests.
- [x] Per-call generation parameters are supported.
- [x] A result type exposes content plus metadata without requiring timeline state.
- [x] Regression tests reproduce the current one-shot hang/no-metadata behavior
  before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit); add a shared-runner conformance suite. Depends on
PKRR-002 (cancellation) and PKRR-011 (terminal event contract). Public API change —
audit `Monad`/`Shuttle`/`Yakamoz` one-shot callers and follow the downstream-sync
checklist.
