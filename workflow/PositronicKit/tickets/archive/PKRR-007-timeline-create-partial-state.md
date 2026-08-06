---
Priority: P1
Type: Timeline lifecycle
Depends on: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Timeline + persistence
Effort: L
Tranche: B (persistence recoverable/idempotent)
Review: PKR-007
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `b513d2c` (fast-forward to main).
Reordered `createTimeline` to persist timeline record first, then create directory/
notes/workspace, with compensating rollback (delete record + remove directory) on failure
at each step. Reordered `attachWorkspace` to validate workspace existence before persisting
attachment. Runtime registration remains best-effort (logged, not thrown). 9 fault-injection
tests. 1465 tests in 219 suites pass on merged main.
---

# PKRR-007 — Timeline creation and workspace attachment can leave partial state

## Summary
Creation writes directories/notes/workspace/cache before the final timeline save.
Attachment is persisted before workspace resolution/registration, whose error is
swallowed. Failures can leak directories, workspace rows, cached managers, or
persisted attachment IDs that are not usable at runtime.

## Current problem
- `Sources/PositronicKit/Services/Timeline/TimelineManager+Lifecycle.swift:9-45` —
  creation writes directories/notes/workspace/cache before the final timeline save.
- `Sources/PositronicKit/Services/Timeline/TimelineManager+Attachments.swift:10-34`
  — attachment is persisted before workspace resolution/registration, whose error is
  swallowed.

## Impact
Failures can leak directories, workspace rows, cached managers, or persisted
attachment IDs that are not usable at runtime. Subsequent retries encounter
inconsistent state.

## Recommended change
Create a lifecycle transaction/saga with ordered commit and compensating rollback.
Validate workspace existence first. Persist the timeline before exposing it in
caches, or maintain a creation state and reconcile on startup.

## Acceptance criteria
- [x] Fault-injection tests at every operation leave no orphan directory/row/cache.
- [x] Attachment failure does not mutate the timeline.
- [x] Startup reconciliation detects and repairs incomplete lifecycle records.
- [x] Regression tests reproduce the current partial-state leakage before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit timeline targets); add a lifecycle-fault-injection
suite. Coordinate with PKRR-029 (temp workspace retention story).
