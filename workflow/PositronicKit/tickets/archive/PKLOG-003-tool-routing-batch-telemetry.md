# PKLOG-003 — Batch-level tool-routing telemetry in `ToolRouter`

**Priority:** P3
**Type:** Observability
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `4378e32`) — `ToolRouter.handlePendingToolCalls` now emits one
aggregate `logger.debug("Tool batch routed")` after the batch loop with `total`/`deferred`/
`resolved`/`failed` counts plus hashed deferred tool-call IDs (`redactedHash`, matching
`ToolCallExtractionStage`) and raw `timelineID` (YAK-37 id). `turnIndex` omitted (not in scope at
this call site). `return ToolHandlingResult` byte-identical; logging-only. `make verify` green
(924 tests / 159 suites, unchanged).

### Summary

`ToolRouter.handlePendingToolCalls()` logs per-tool outcomes as separate `.debug` lines
but never records the turn's overall routing disposition. Debugging "a deferred tool
that never returned" requires manually correlating scattered log lines.

### Current Problem

`Sources/PositronicKit/Services/Tools/ToolRouter.swift:149–212` — per-tool `.debug`
calls only; no aggregate after the batch loop (~line 191).

### Implementation Requirements

1. After the batch loop, emit one `.info`/`.debug` entry with structured metadata:
   `{ total, deferred, resolved, failed }` counts plus timeline/turn identifiers.
2. Include the deferred tool-call IDs (hashed, consistent with the existing
   `ToolCallExtractionStage` hashing convention) so a later resolution can be matched.

### Acceptance Criteria

- [ ] One aggregate log entry per tool batch with disposition counts.
- [ ] `make verify` green; no behavior change.
