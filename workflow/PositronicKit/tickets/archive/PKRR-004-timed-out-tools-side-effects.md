---
Priority: P0
Type: Tools / side effects
Depends on: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Tool runtime
Effort: L
Tranche: A (lock terminal/execution invariants)
Review: PKR-004
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Design spec: workflow/PositronicKit/specs/2026-07-28-pkrr-004-005-017-design-decisions.md
Decision: capability flag + uncertain result (2026-07-28)
Resolution: Implemented 2026-07-28. PositronicKit `16c1ed3` (merge `82fd645`). Added
public `ToolSideEffects` enum (`.none`/`.mutating`/`.externalProcess`) to PKShared with
`.mutating` default; `AnyTool` forwards it. `ToolTimeoutEnforcer` throws
`ToolError.timedOutButMayStillBeRunning` (error code 212) for `.mutating`/`.externalProcess`,
clean `executionFailed` for `.none`. Basic timeout-value validation + overflow-safe
nanosecond clamping. 11 new tests (ToolSideEffects + enforcer). Additive/backward-compatible.
1369 tests in 208 suites pass on merged main.
---

# PKRR-004 — Timed-out tools are abandoned and may keep mutating state after failure is reported

## Summary
`ToolTimeoutEnforcer`'s contract explicitly abandons uncooperative tool tasks after
timeout. A write-capable tool can therefore complete side effects after the
model/UI receives a timeout, and the runtime cannot truthfully claim the operation
stopped.

## Current problem
- `Sources/PositronicKit/Services/Tools/ToolTimeoutEnforcer.swift:7-17` — the
  contract explicitly abandons uncooperative tool tasks after timeout.
- `Sources/PositronicKit/Services/Tools/ToolTimeoutEnforcer.swift:47-102` — the
  timeout branch cancels best-effort, finishes the race, and returns immediately.

## Impact
A write-capable tool can complete side effects after the model/UI receives a
timeout. Retrying can duplicate writes, commands, payments, file changes, or remote
operations. The runtime cannot truthfully claim the operation stopped.

## Recommended change
Per the design decision (2026-07-28): **capability flag + uncertain result**.

Add a `ToolSideEffects` enum (`.none`/`.mutating`/`.externalProcess`) to the public
`Tool` protocol with a default of `.mutating` (conservative). `ToolTimeoutEnforcer`:
- `sideEffects == .none`: preserve current fast-abandon behavior (clean timeout).
- `sideEffects == .mutating` or `.externalProcess`: cancel best-effort but return a
  distinct `timedOutButMayStillBeRunning` terminal state (not a clean timeout). The
  enforcer does NOT block waiting for the uncooperative tool — the uncertain result
  is returned promptly; only the *reported* status changes.

No idempotency keys, no kill hook, no `ToolTerminatable` protocol in this ticket.
Those are explicitly deferred — the capability flag + honest status is the minimum
viable correctness improvement.

## Acceptance criteria
- [x] Mutating tool tests prove the `timedOutButMayStillBeRunning` state is produced
  (not a clean timeout) for `.mutating`/`.externalProcess` tools.
- [x] Side-effect-free (`.none`) tools preserve the current fast-abandon clean
  timeout.
- [x] `ToolSideEffects` is a public type on `PKShared` with a `.mutating` default.
- [x] The `timedOutButMayStillBeRunning` state is a typed `ToolResult`/`ToolError`
  case, not a string.
- [x] Timeout values are finite, non-negative, and overflow-safe (relates to
  PKRR-030).
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit tool targets); add a timeout-side-effect-invariant
suite. Public API change — audit `Monad`/`Shuttle`/`Yakamoz` tool conformers and
follow the downstream-sync checklist.
