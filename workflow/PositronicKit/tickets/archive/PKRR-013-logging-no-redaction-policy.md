---
Priority: P1
Type: Logging / privacy
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Cross-cutting
Effort: M
Tranche: D (observability, API hygiene, build confidence)
Review: PKR-013
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `674d229` (merge `faa4bcc`). Added
`LoggingConfiguration` with default-off `LogRedactionPolicy` injectable through
`PositronicKit.Configuration`. Request descriptions, malformed tool arguments, tool errors,
ANSI escapes, and emoji no longer enter default structured logs. Error logs carry stable
domain, code, and correlation metadata. 1518 tests in 224 suites pass on merged main.
---

# PKRR-013 — Logging lacks a coherent injection and redaction policy and can expose payload fragments

## Summary
`ChatRunRequest.description` includes the full user message; malformed tool
arguments log a raw 120-character prefix; tool events/logs use raw localized errors
and emit before durable persistence; modules construct global loggers directly so
hosts cannot inject a per-kit policy. Prompt/tool/error data can leak into logs or
UI events, and ANSI escape codes and emoji are embedded in structured messages.

## Current problem
- `Sources/PositronicKit/ChatRunRequest.swift:54-62` — `description` includes the
  full user message.
- `Sources/PositronicKit/Services/Chat/Stages/MessagePersistenceStage.swift:121-142`
  — malformed tool arguments log a raw 120-character prefix.
- `Sources/PositronicKit/Services/Tools/ToolRouter.swift:426-474` — tool events/logs
  use raw localized errors and emit before durable persistence.
- `Sources/PKUtilities/Logger+Extensions.swift:7-18` — modules construct global
  loggers directly; hosts cannot inject a policy per kit.

## Impact
Prompt/tool/error data can leak into logs or UI events. Modules are hard to test and
route consistently. ANSI escape codes and emoji are embedded in structured logging
messages (see also PKRR-024).

## Recommended change
Add a `LoggingConfiguration`/logger factory to `PositronicKit.Configuration`,
central redaction helpers, payload logging disabled by default, and structured
metadata for codes/IDs. Remove ANSI coloring from swift-log records; leave
presentation to handlers.

## Acceptance criteria
- [x] Default logs contain no prompt, tool-argument, response-body, or secret
  fragments.
- [x] All errors carry stable code/domain plus correlation IDs (relates to
  PKRR-014).
- [x] A host can inject a logger factory and redaction policy.
- [x] JSON log snapshots contain no ANSI escapes (relates to PKRR-024).
- [x] Regression tests reproduce the current payload leakage before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit + PKUtilities); add a logging-redaction suite. Public
API change (logger factory on Configuration) — audit `Monad`/`Shuttle`/`Yakamoz`
logger wiring and follow the downstream-sync checklist.
