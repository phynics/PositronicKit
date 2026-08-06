---
Priority: P2
Type: Logging format
Depends: —
Blocks: —
Triage: needs-triage
Status: Done
Confidence: Confirmed
Owner: PKUtilities
Effort: S
Tranche: D (observability, API hygiene, build confidence)
Review: PKR-024
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `a3d40d8` (fast-forward to main). Added
`colorize(_:color:enabled:)` gate and `strip(_:)` to `ANSIColors`.
`LogRedactionPolicy.sanitize` delegates to `ANSIColors.strip`. Legacy `colorize(_:color:)`
kept public for downstream consumers. 10 regression tests. 1576 tests in 235 suites pass
on merged main.
---

# PKRR-024 — ANSI color codes and presentation glyphs are embedded in swift-log records

## Summary
`ANSIColors` always inserts escape sequences with no TTY/handler detection. Colored
timeline IDs, colored tool names, and emoji are placed in log messages. JSON, OSLog,
files, and telemetry receive escape bytes and presentation-specific strings,
complicating searching and parsing.

## Current problem
- `Sources/PKUtilities/ANSIColors.swift:6-34` — colorization always inserts escape
  sequences with no TTY/handler detection.
- `Sources/PositronicKit/Services/Chat/ChatEngine.swift:169-172` — colored timeline
  IDs are put in log messages.
- `Sources/PositronicKit/Services/Tools/ToolRouter.swift:219-232` — colored tool
  names and emoji are used in logs.

## Impact
JSON, OSLog, files, and telemetry receive escape bytes and presentation-specific
strings, complicating searching and parsing.

## Recommended change
Keep log messages plain and structured. Implement optional color only in a terminal
log handler. Use metadata fields for tool/timeline identity.

## Acceptance criteria
- [x] Structured handlers receive printable plain text.
- [x] Terminal color is opt-in and handler-owned.
- [x] Regression tests reproduce the current ANSI-in-records output before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PKUtilities + PositronicKit). Coordinate with PKRR-013 (logging
policy). Note: `ANSIColors`/`VectorMath` were kept public in PKV3-007 because of
real downstream consumers — verify those consumers before changing the surface.
