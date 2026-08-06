---
Priority: P2
Type: Feature story / workspace ownership
Depends: —
Blocks: —
Triage: needs-triage
Status: Done
Confidence: Confirmed
Owner: Timeline/workspace
Effort: M
Tranche: D (observability, API hygiene, build confidence)
Review: PKR-029
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-29. PositronicKit `671a29c`. Added explicit workspace profiles,
retention and cleanup behavior, configurable seed notes, and regression coverage for failed
workspace creation. Final merged main verification passed with 1598 tests in 237 suites.
---

# PKRR-029 — Timeline creation writes default note files into a temporary workspace without a lifecycle/retention story

## Summary
The default workspace root is the process temporary directory, and every new
timeline writes `Notes/Welcome.md` and `Notes/Project.md`. A minimal chat runtime
has hidden filesystem side effects, potentially leaves temporary data, and injects
opinionated note content. The persistence relationship between timeline records and
temporary directories is unclear after restart or cleanup.

## Current problem
- `Sources/PositronicKit/PositronicKit.swift:156-175` — the default workspace root
  is the process temporary directory.
- `Sources/PositronicKit/Services/Timeline/TimelineManager+Lifecycle.swift:166-207`
  — every new timeline writes `Notes/Welcome.md` and `Notes/Project.md`.

## Impact
A minimal chat runtime has hidden filesystem side effects, potentially leaves
temporary data, and injects opinionated note content. The persistence relationship
between timeline records and temporary directories is unclear after restart or
cleanup.

## Recommended change
Make workspace creation an explicit profile. Define ownership, retention, cleanup,
and migration semantics. Allow `noWorkspace`, `ephemeralWorkspace`, and
host-managed persistent workspace policies; make seed content configurable.

## Acceptance criteria
- [ ] Minimal one-shot/timeline use has documented filesystem behavior.
- [ ] Temporary workspaces are cleaned deterministically.
- [ ] Hosts can disable or replace seeded notes.
- [ ] Regression tests reproduce the current hidden temp-directory side effects
  before the fix.
- [ ] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit); add a workspace-lifecycle/retention suite. Coordinate
with PKRR-007 (lifecycle transactions) and PKRR-017 (durability profiles). Public
API change — audit `Monad`/`Shuttle`/`Yakamoz` workspace defaults and follow the
downstream-sync checklist.
