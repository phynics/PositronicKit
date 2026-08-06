---
Priority: P1
Type: Tool routing / safety
Depends on: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Tool runtime
Effort: S
Tranche: B (persistence recoverable/idempotent)
Review: PKR-015
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `8d5bd21` (fast-forward to main). When
workspaceID is present in tool arguments, require a valid UUID matching a candidate
workspace. Malformed values throw ToolError.invalidWorkspaceID (error code 213);
valid-but-unmatched UUIDs throw workspaceNotFound. No more silent fallback to
auto-routing. 3 fail-closed regression tests. 1440 tests in 216 suites pass on merged main.
---

# PKRR-015 — A malformed explicit `workspaceID` silently falls back to automatic routing

## Summary
The explicit-routing branch in `ToolRouter` runs only when the value is a string that
parses as a UUID; otherwise normal auto-resolution continues. A caller/model that
attempted to target a workspace but supplied malformed input may execute against a
different workspace — surprising and not fail-closed.

## Current problem
- `Sources/PositronicKit/Services/Tools/ToolRouter.swift:338-350` — the explicit
  branch runs only when the value is a string that parses as UUID; otherwise normal
  auto-resolution continues.

## Impact
A caller/model that attempted to target a workspace but supplied malformed input may
execute against a different workspace. This is surprising and not fail-closed.

## Recommended change
If the key is present, require a string UUID and require membership in candidates;
otherwise throw `invalidWorkspaceID`. Consider removing routing-only fields from
model-visible arguments and passing workspace intent in a typed envelope.

## Acceptance criteria
- [x] Present-but-invalid `workspaceID` always fails before tool execution.
- [x] No fallback workspace is selected after explicit-intent validation failure.
- [x] Regression test reproduces the current silent fallback before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit tool targets); add a workspace-routing fail-closed
suite.

## Notes
This finding was not assigned to any tranche by the review; placed in Tranche B
thematically — tool-runtime fail-closed safety pairs with PKRR-016's durable
tool-event ordering.
