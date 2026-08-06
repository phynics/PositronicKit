# PKFLAKE-006 — Deflake time-dependent tests and inject a clock where wall-clock leaks in

**Priority:** P2
**Type:** Test reliability
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `1b46532`) — `ContextManagerCancellationTests` and
`TimelineManagerTests.taskCancellation` replaced fixed-duration sleeps/polls with
`Task.yield()`-driven polling against a generous 5s `ContinuousClock` deadline (guards only
against a genuine hang, not scheduling variance). `ToolTimeoutEnforcerTests`'
`realTimeoutWinsRealSleep`/`realTimeoutWinsUncooperative` (the two tests intentionally left
untouched by PKFLAKE-003) had their real-`Task.sleep` timeouts widened `0.01s/0.05s → 0.2s` and
the elapsed-time assertion widened `<1s → <5s` — both still exercise the real default `sleep`
path, just without razor-thin margins. `MemoryModelTests.testMemoryUpdate`'s `usleep(1000)` was
dead code (the assertion is an equality check, not an ordering check) and was deleted outright.
`NaturalLanguageEmbeddingTests` gained an `NLEmbedding.sentenceEmbedding` availability probe with
`@Suite(.disabled(if:...))` to skip gracefully on hosts without provisioned NL assets.
`ContextRanker.rankMemories` gained an additive `now: @escaping () -> Date = Date.init` parameter
(source-compatible; the one production call site and 3 existing tests are unaffected); a new
`ContextRankerTests` test pins the clock and asserts exact decay factors (0.5 at 42 days, 0.25 at
84 days) with zero wall-clock dependency. `RetryPolicy`'s jitter was audited — no test asserts an
exact elapsed duration through real jitter, so no change was needed there. Full suite run twice
in a row: 902 tests / 157 suites, green both times.

### Summary

Several tests depend on real sleeps, tight wall-clock margins, or machine state, and one
production component ranks by raw `Date()`. These pass locally but will fail under CI
scheduling pressure or on fresh machines.

### Current Problem

- `Tests/PositronicKitTests/ContextManagerCancellationTests.swift:35,48` — 100 ms sleep
  to "let cancellation propagate"; no deadline on the awaited result.
- `Tests/PositronicKitTests/TimelineManagerTests.swift:115,129` — 10×10 ms polling loop
  for a cancellation flag; exhausts under load.
- `Tests/PositronicKitTests/Services/ToolTimeoutEnforcerTests.swift:134–166` — real-time
  races with 0.01 s/0.05 s timeouts asserting `elapsed < 1 s`; `Task.sleep` oversleep
  under load breaks these.
- `Tests/PositronicKitTests/Models/Database/MemoryModelTests.swift:47` — `usleep(1000)`
  to force timestamp ordering; fails where `Date()` resolution is coarse.
- `Tests/PKLocalEmbeddingsTests/NaturalLanguageEmbeddingTests.swift` — fails (rather
  than skips) when Apple's `NLEmbedding` assets are not downloaded on the host.
- `Sources/PositronicKit/Services/Context/ContextRanker.swift:26` — age decay uses
  `Date()` at call time; same inputs can rank differently across a second boundary and
  tests cannot pin decay behavior.

### Implementation Requirements

1. Replace sleeps/polls with deterministic synchronization (confirmations from mocks,
   `AsyncStream` signals, or the existing injectable-sleep seams). Where a real-time
   bound is unavoidable, widen margins to CI-safe values and mark why.
2. `MemoryModelTests`: inject the timestamp or compare with explicit dates instead of
   `usleep`.
3. `NaturalLanguageEmbeddingTests`: probe `NLEmbedding.sentenceEmbedding(for: .english)`
   availability first and skip (Swift Testing: conditional trait / early return with a
   recorded skip) instead of failing.
4. `ContextRanker`: inject a `now: () -> Date` (or `Clock`) with a `Date.init` default;
   add a test pinning decay math with a fixed clock. Check consumers for constructor
   call sites before changing the signature (default argument keeps API compatible).
5. `RetryPolicy` jitter (`Utilities/RetryPolicy.swift:69`): ensure no test asserts exact
   elapsed durations through real jitter; inject the RNG or assert on bounds only.

### Acceptance Criteria

- [ ] No test relies on a bare `Task.sleep`/`usleep` for correctness (documented
      exceptions only, with CI-safe margins).
- [ ] Embedding availability test skips gracefully on unprovisioned hosts.
- [ ] `ContextRanker` decay is testable with an injected clock.
- [ ] `make verify` green, run twice to spot-check stability.
