---
Priority: P1
Type: Validation / crash safety
Depends: —
Blocks: PKRR-021
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: PKPrompt + Runtime
Effort: M
Tranche: C (cross-platform generation + public contracts)
Review: PKR-020
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `f08730c` (merged in `ecd0b63`). Replaced
recoverable preconditions with typed errors; missing prompt diffs now fail only the affected
turn with diagnostic state. Added duplicate-ID, invalid-budget, and journal-transition
regression/property coverage. Retained only the genuinely impossible internal assertion.
1504 tests in 222 suites pass on the agent branch; merged gate passes with 1510 tests.
---

# PKRR-020 — Public and runtime paths use preconditions for recoverable invalid state

## Summary
Duplicate section IDs trigger a `precondition` in a public API path, and a missing
prompt diff triggers `preconditionFailure`. Malformed extension input or an internal
journal inconsistency can terminate the host process instead of failing one request
— unsuitable for a production library.

## Current problem
- `Sources/PKPrompt/PromptAssembly/Compression/TokenBudget.swift:94-100` —
  duplicate section IDs trigger `precondition` in a public API path.
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnPreparation.swift:124-128` —
  a missing prompt diff triggers `preconditionFailure`.

## Impact
Malformed extension input or an internal journal inconsistency can terminate the
host process instead of failing one request. That is unsuitable for a production
library.

## Recommended change
Replace preconditions with typed errors at trust boundaries. Reserve assertions for
impossible debug-only invariants after validation. Add fuzz/property tests around
prompt IDs, budgets, and journal transitions.

## Acceptance criteria
- [x] No caller-controlled prompt composition can crash the process.
- [x] Journal inconsistency terminates only the affected turn with diagnostic state.
- [x] Fuzz/property tests cover prompt IDs, budgets, and journal transitions.
- [x] Regression tests reproduce the current crash-before-throw behavior before the
  fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PKPrompt + PositronicKit); add a no-crash-on-invalid-input suite.
Unblocks PKRR-021's throwing budget API.
