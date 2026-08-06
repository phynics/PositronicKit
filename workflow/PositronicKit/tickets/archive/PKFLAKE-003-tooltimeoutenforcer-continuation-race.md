# PKFLAKE-003 — `ToolTimeoutEnforcer`: unstructured Tasks inside checked continuation

**Priority:** P2
**Type:** Bug (cancellation race / potential continuation misuse)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `8c2d4e1`) — `ToolTimeoutEnforcer.execute` no longer uses
`withCheckedThrowingContinuation`. A `withThrowingTaskGroup` was tried first but rejected: a
task group waits for every child (even cancelled ones) before its body returns, so racing an
uncooperative blocking tool (`Thread.sleep`, ignores cancellation) would tie the timeout path
to the tool's full uncooperative duration — defeating the enforcer's "abandon and return
immediately" purpose (confirmed via a failing `fakeClockTimeoutBoundsUncooperativeTool`, elapsed
jumped to 3s). Landed instead: two ad hoc `Task`s reporting into a shared `AsyncStream`, which
tolerates a straggling loser resolving after the winner (unlike `CheckedContinuation`, which
traps on double-resume); outer cancellation cancels both tasks and finishes the stream via
`withTaskCancellationHandler`. `TimeoutRaceResolver` (the actor guarding the old continuation)
was deleted as dead code. Added a deterministic cancellation-mid-race test
(`externalCancellationPropagates`) using a parked `Task.sleep(for: .seconds(3600))` cancellable
park-point, no real-time waits. `swift test`: 897 tests / 156 suites green.

### Summary

`ToolTimeoutEnforcer` starts the tool-completion and timeout paths as bare `Task {}`
blocks inside `withCheckedThrowingContinuation`. These are not structured children: on
cancellation mid-race they cannot be cancelled and may resume (or double-resume) a
continuation that has already been settled.

### Current Problem

`Sources/PositronicKit/Services/Tools/ToolTimeoutEnforcer.swift:63–85` — two bare
`Task { }` blocks race to `claim()` the continuation; the `withTaskCancellationHandler`
`onCancel` path cancels `toolTask`/`timeoutTask` but not these inner tasks.

### Implementation Requirements

1. Restructure the race using structured concurrency — e.g. `withThrowingTaskGroup`
   racing the tool call against the (injectable) sleep, cancelling the loser — removing
   the checked continuation entirely if possible.
2. Preserve the injectable `sleep` closure seam used by the existing fake-clock tests
   (`ToolTimeoutEnforcerTests`).
3. Keep behavior: first finisher wins; timeout throws the existing timeout error;
   external cancellation propagates promptly and never leaks an orphaned task.
4. Add a cancellation-mid-race regression test using the injected fake clock (no real
   sleeps).

### Acceptance Criteria

- [ ] No bare `Task {}` inside a continuation in `ToolTimeoutEnforcer`.
- [ ] Existing 9 `ToolTimeoutEnforcerTests` pass (recast where APIs changed internally).
- [ ] New cancellation-race test, deterministic (fake clock).
- [ ] `make verify` green.
