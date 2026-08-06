---
Priority: P1
Type: Pipeline / cancellation
Depends on: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: PKUtilities
Effort: M
Tranche: B (persistence recoverable/idempotent)
Review: PKR-009
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `64ed6a0` (merge `e226d47`). runPrimaryStages
returns CancellationError() when Task.isCancelled instead of breaking and returning nil.
Cleanup failures collected and returned as PipelineError.compoundFailure (error code 4003)
so both primary and cleanup failures are observable. Cleanup always runs even after
cancellation. 4 cancellation-invariant tests + 1 updated existing test. 1440 tests in 216
suites pass on merged main.
---

# PKRR-009 — Pipeline cancellation can be reported as success, and cleanup failures can be hidden

## Summary
In `PKUtilities.Pipeline`, cancellation between stages breaks the primary loop and
can return no error; cleanup failures are ignored when a prior error exists. Only
errors thrown inside a stage become `PipelineError`; cancellation is not checked
after iteration. A cancelled pipeline may finish normally, and compound cleanup
failures are only observable via logs.

## Current problem
- `Sources/PKUtilities/Pipeline.swift:99-125` — cancellation between stages breaks
  the primary loop and can return no error; cleanup failures are ignored when a
  prior error exists.
- `Sources/PKUtilities/Pipeline.swift:128-160` — only errors thrown inside a stage
  become `PipelineError`; cancellation is not checked after iteration.

## Impact
A cancelled pipeline may finish normally. If primary and cleanup both fail, only the
primary error is observable unless a log handler was configured, obscuring
resource-cleanup failures.

## Recommended change
Call `Task.checkCancellation()` before and after every stage and before successful
finish. Model compound failures (primary plus cleanup failures) or attach cleanup
failures as structured diagnostics. Ensure cleanup runs in a cancellation-aware but
non-skippable context.

## Acceptance criteria
- [x] Cancellation between stages always throws cancellation.
- [x] Multiple cleanup failures are observable without log scraping.
- [x] Tests cover cancellation before first, between, and after final stage.
- [x] Regression tests reproduce the current cancel-as-success and hidden-cleanup
  behavior before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PKUtilities); add a pipeline-cancellation-invariant suite. Relates to
PKRR-014 (pipeline wrapping destroys error identity).
