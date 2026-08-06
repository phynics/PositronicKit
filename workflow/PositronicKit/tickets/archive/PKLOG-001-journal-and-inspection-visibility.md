# PKLOG-001 — Log prompt-journal updates and turn-inspection skips

**Priority:** P2
**Type:** Observability
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `7e89b06`) — after a successful `promptHistory.update(prompt:)`,
`TurnPreparer` now logs a `.debug` line with `addedSections`/`removedSections`/`changedSections`
counts (`diff.added/removed/changed.count`) plus `timelineID`/`sendID`/`turnIndex` metadata.
`TurnLoopController.publishTurnInspectionIfNeeded`'s compound guard is split into four named
guards, each logging at `.debug` which precondition failed (no inspector / no rendered prompt /
no history update / no diff). Structured `Logger.Metadata` matching `ToolCallExtractionStage`.
Logging-only, no behavior change; `make verify` green (924 tests / 159 suites, unchanged).

### Summary

The two key audit-trail points in the turn loop are silent: a successful
`promptHistory.update(prompt:)` produces no log (journal staleness is undiagnosable),
and `publishTurnInspectionIfNeeded()` skips silently when any of its four guards fail
(an operator asking "why didn't my inspector fire?" gets nothing).

### Current Problem

- `Sources/PositronicKit/Services/Chat/TurnPreparer.swift:129–138` — logging covers
  section counts and compression but not journal-update completion.
- `Sources/PositronicKit/Services/Chat/TurnLoopController.swift:231–238` — four
  `guard let`s (`inspector`, `renderedPrompt`, `promptHistoryUpdate`, `diff`) with no
  `else` logging.

**Sequencing note:** PKDEEP2-001 proposes folding `TurnPreparer`/`TurnLoopController`
back into `ChatEngine`. If it lands first, apply these changes at the folded locations.

### Implementation Requirements

1. After a successful `promptHistory.update()`, log at `.debug` with structured metadata:
   timeline ID, turn count, diff summary (added/removed/changed section counts).
2. In `publishTurnInspectionIfNeeded()`, when skipping, log at `.debug` naming which
   precondition failed (e.g. "no turn inspector registered" vs "prompt diff unavailable").
3. Use `Logger.Metadata` (structured), matching the pattern in
   `ToolCallExtractionStage`.

### Acceptance Criteria

- [ ] Journal writes and inspection skips are visible in logs with reasons.
- [ ] No behavior change; `make verify` green.
