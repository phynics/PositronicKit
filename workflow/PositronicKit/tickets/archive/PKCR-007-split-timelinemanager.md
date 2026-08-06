---
Priority: P2
Type: File splitting / refactoring
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: High
Owner: —
Effort: M
Review: Code review 2026-07-29
Pinned revision: a354632
Resolution: Completed 2026-07-29. Extracted TimelineManager convenience initializers into
TimelineManager+Init.swift and public result/error types into TimelineManagerTypes.swift.
Build and TimelineManager tests passed; full verification passed with 1610 tests in 238 suites.
---

# PKCR-007 — Split TimelineManager.swift (682 lines)

## Summary

`TimelineManager.swift` is the largest file in the codebase at 682 lines. ~265 lines are init overloads (11 initializers), and 4 trailing public types (`TimelineError`, `StoreDegradation`, `WorkspaceQueryResult`, `TimelineDeletionResult`) could live in a separate file.

## Current problem

- `Sources/PositronicKit/Services/Timeline/TimelineManager.swift:134-399` — 11 initializers (~265 lines), mostly backward-compatibility convenience overloads.
- `Sources/PositronicKit/Services/Timeline/TimelineManager.swift:554-682` — 4 public types (`TimelineError`, `StoreDegradation`, `WorkspaceQueryResult`, `TimelineDeletionResult`) appended after the actor definition.

## Implementation requirements

1. Extract the 4 trailing public types to `TimelineManagerTypes.swift`:
   - `TimelineError` (lines 554-608)
   - `StoreDegradation` (lines 609-633)
   - `WorkspaceQueryResult` (lines 634-652)
   - `TimelineDeletionResult` (lines 653-682)
2. Extract the 11 initializers to `TimelineManager+Init.swift` as a `private extension TimelineManager` (or `internal extension` if needed for test access).
3. Keep the main `TimelineManager.swift` focused on: stored properties, the designated init, query methods, task management, and tool management.
4. Follow the existing `+Lifecycle.swift` / `+Attachments.swift` extension-file pattern.
5. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [ ] `TimelineManagerTypes.swift` created with the 4 extracted types.
- [ ] `TimelineManager+Init.swift` created with the init overloads.
- [ ] `TimelineManager.swift` reduced to ~300 lines (designated init + core methods).
- [ ] All existing extension files (`+Lifecycle`, `+Attachments`) still compile.
- [ ] `swift build` succeeds.
- [ ] `swift test` passes (1598+ tests).
- [ ] `CHANGELOG.md` updated.
