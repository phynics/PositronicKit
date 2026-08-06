---
Priority: P2
Type: Lifecycle API ergonomics
Depends on: PKRR-002
Blocks: —
Triage: needs-triage
Status: Done
Confidence: Confirmed
Owner: Timeline API
Effort: S
Tranche: B (persistence recoverable/idempotent)
Review: PKR-023
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `bc91aec` (fast-forward to main). Renamed
`deleteTimeline` to `evictTimelineFromMemory` (cancels/drains active work via
`TimelineTaskRegistry` before eviction). Added `deleteTimelinePermanently` returning
`TimelineDeletionResult` with partial-cleanup reporting. Deprecated alias retained for
backward compatibility. 7 eviction/deletion regression tests. 1583 tests in 236 suites pass
on merged main.
---

# PKRR-023 — `deleteTimeline` only evicts memory and does not cancel active work

## Summary
`deleteTimeline` is explicitly an in-memory eviction: it does not touch
persistence, and active tasks live in a separate cache. The name suggests durable
deletion; callers can leak persisted data and active work, and the eviction can
race with a task that repopulates state after eviction.

## Current problem
- `Sources/PositronicKit/Services/Timeline/TimelineManager+Lifecycle.swift:90-125`
  — `deleteTimeline` is explicitly an in-memory eviction and does not touch
  persistence.
- `Sources/PositronicKit/Services/Timeline/TimelineManager.swift:65-75` — active
  tasks are a separate cache.

## Impact
The name suggests durable deletion. Callers can leak persisted data and active work.
The operation can race with a task that repopulates state after eviction.

## Recommended change
Rename to `evictTimelineFromMemory` and add a true
`deleteTimelinePermanently` transaction. Both paths should cancel and drain active
work before state removal (depends on the task registry from PKRR-002).

## Acceptance criteria
- [x] API names reflect durability semantics.
- [x] No active task survives eviction/deletion.
- [x] Permanent delete removes all related persisted records or reports partial
  cleanup.
- [x] Regression tests reproduce the current leak/race before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit timeline targets). Public API rename — audit
`Monad`/`Shuttle`/`Yakamoz` `deleteTimeline` callers and follow the downstream-sync
checklist. Depends on PKRR-002's task registry.
