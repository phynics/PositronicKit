---
Priority: P1
Type: Error handling
Depends on: —
Blocks: PKRR-005
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Runtime
Effort: M
Tranche: B (persistence recoverable/idempotent)
Review: PKR-008
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `624ed02` (fast-forward to main). Expanded
TimelineError with corrupt/permissionDenied/invalidState cases. Replaced try? in
TimelineManager+Lifecycle, +Attachments, and getToolSource with typed error propagation.
getWorkspaces now throws WorkspaceQueryResult with StoreDegradation diagnostics. 21
store-error-classification tests. 1434 tests in 215 suites pass on merged main.
---

# PKRR-008 — Persistence and resolution errors are repeatedly collapsed into not-found or empty results

## Summary
`try?` turns title-fetch failures into `timelineNotFound`; timeline/workspace fetch
failures become `nil` or skipped entries; tool-source persistence failure becomes
`nil`. Outages and corruption look like missing data, and operators lose causal
information.

## Current problem
- `Sources/PositronicKit/Services/Timeline/TimelineManager+Lifecycle.swift:72-88` —
  `try?` turns title-fetch failures into `timelineNotFound`.
- `Sources/PositronicKit/Services/Timeline/TimelineManager+Attachments.swift:61-88`
  — timeline/workspace fetch failures become `nil` or skipped entries.
- `Sources/PositronicKit/Services/Timeline/TimelineManager.swift:339-354` —
  tool-source persistence failure becomes `nil`.

## Impact
Outages and corruption look like missing data. The runtime may route tools
incorrectly, omit context, or tell users an entity does not exist. Operators lose
causal information.

## Recommended change
Define a small error taxonomy (`notFound`, `unavailable`, `corrupt`,
`permissionDenied`, `invalidState`) and only downgrade explicitly documented
optional features. Return typed partial-result diagnostics where best-effort
behavior is intended.

## Acceptance criteria
- [x] Store outage tests never surface as `not-found`.
- [x] Best-effort APIs return diagnostics/health degradation rather than silent
  empty results.
- [x] Logs include stable error identity and operation metadata.
- [x] Regression tests reproduce the current error-collapsing behavior before the
  fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit); add a store-error-classification suite. This taxonomy
is a prerequisite for PKRR-005's not-found vs unavailable distinction and
PKRR-022's degradation policy.
