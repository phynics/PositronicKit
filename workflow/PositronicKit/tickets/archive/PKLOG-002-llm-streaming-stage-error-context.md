# PKLOG-002 — Log stream-failure context in `LLMStreamingStage`

**Priority:** P2
**Type:** Observability
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `60d6ab5`) — `LLMStreamingStage.process(_:)`'s outer error
catch (previously bare `continuation.finish(throwing: error)`) now logs at `.error` first:
elapsed time since stream start (`ContinuousClock`/`Duration`, matching the file's existing
`StreamIdleDeadline` idiom), accumulated response/thinking char counts and tool-call delta count
(read from `context.outputs`, the `TurnOutputs` actor), and `ErrorKit.userFriendlyMessage(for:
error)`. Logging-only — the thrown/finished error is byte-identical to before, `TurnLoopController`'s
downstream catch/log is untouched, and no `PKError`-conforming wrapper type was introduced (that's
explicitly deferred to PKLOG-004, which hasn't landed yet). `make verify` green (924 tests / 159
suites, unchanged — no new tests, per the ticket's own AC of "existing tests still pass").

### Summary

When the LLM stream throws or times out, `LLMStreamingStage` passes the error to
`continuation.finish(throwing:)` with no stage-level logging; by the time
`TurnLoopController.runOneTurn()` logs it, the partial stream state (accumulated
response/thinking chars, chunks processed) is opaque. Stream failures are the most
common production incident and currently the hardest to debug.

### Current Problem

`Sources/PositronicKit/Services/Chat/Stages/LLMStreamingStage.swift:70–74` — error path
has no logging; the stage's only log line is a debug flush at line 257.

### Implementation Requirements

1. Before re-throwing/finishing with an error, log at `.error` with structured metadata:
   accumulated response chars, thinking chars, tool-call delta count, elapsed time, and
   the error via `ErrorKit.userFriendlyMessage(for:)`.
2. Consider wrapping generic provider transport errors in a `PKError`-conforming type
   carrying this context (coordinate with PKLOG-004 on error-domain consistency).
3. No behavior change to the error propagation itself.

### Acceptance Criteria

- [ ] Stream failures produce one stage-level structured log entry with partial-state
      context.
- [ ] Existing `ChatEngineTests` timeout/error tests still pass.
- [ ] `make verify` green.
