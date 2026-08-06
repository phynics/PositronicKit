---
Priority: P0
Type: Timeline lifecycle
Depends on: —
Blocks: PKRR-006
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Runtime API
Effort: M
Tranche: A (lock terminal/execution invariants)
Review: PKR-005
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Design spec: workflow/PositronicKit/specs/2026-07-28-pkrr-004-005-017-design-decisions.md
Decision: fail-closed open + explicit create (2026-07-28)
Resolution: Implemented 2026-07-28. PositronicKit `4bd8baa` (merge `5fb845b`).
`openTimeline(_:)` doc updated to open-existing-only. `resolveTurnBriefingBuilder` is now
`throws`; calls `ensureTimelineExists` instead of swallowing hydration errors. Added
`TimelineError.unavailable` (code 6002) for store failures, distinguishable from
`timelineNotFound` (6001). `ChatEngine+TurnPreparation` validates existence before
`saveConversationSteps`. 4 existing test files updated to create timelines first. 6 new
lifecycle-invariant tests. All 3 consumers already create explicitly — no downstream
migration. 1369 tests in 208 suites pass on merged main.
---

# PKRR-005 — `openTimeline` promises create-on-first-send behavior that the implementation does not provide

## Summary
`openTimeline` documents that a future ID is valid and the first send hydrates or
creates its timeline. In practice hydration errors are logged and the turn proceeds
unhydrated, and the user input is persisted before timeline existence is
established — so messages can be written under an ID with no timeline/workspace
record.

## Current problem
- `Sources/PositronicKit/TimelineDriver.swift:41-48` — documentation says a future
  ID is valid and first send hydrates or creates its timeline.
- `Sources/PositronicKit/PositronicKit.swift:347-373` — hydration errors are logged
  and the turn proceeds unhydrated.
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnPreparation.swift:44-50` —
  the user input is persisted before timeline existence is established.

## Impact
Messages can be written under an ID with no timeline/workspace record. Tool/context
behavior silently degrades, and the public contract is misleading. Store outages
are treated the same as a brand-new ID.

## Recommended change
Per the design decision (2026-07-28): **fail-closed open + explicit create**.

`openTimeline(_:)` becomes open-existing-only. Sending to a missing timeline ID
throws typed `TimelineError.timelineNotFound` **before any message is persisted**.
`createTimeline(...)` is the distinct creation API. No auto-creation on send.

Specific changes:
1. `openTimeline(_:)` doc updated: opens an **existing** timeline; missing ID is
   an error.
2. `resolveTurnBriefingBuilder` (`PositronicKit.swift:352-372`): hydration failure
   is no longer swallowed — `timelineNotFound` propagates as a typed error to the
   caller before `saveConversationSteps` runs.
3. `ChatEngine+TurnPreparation.swift:44-50`: user input is no longer persisted
   before timeline existence is established. Hydrate/validate first, then persist.
   Coordinated with PKRR-006 (idempotent persistence unit-of-work).
4. `createTimeline(title:)` remains the explicit creation path. No "create on
   first send" path is added.

## Acceptance criteria
- [x] Sending to a missing ID throws `TimelineError.timelineNotFound` before
  `saveConversationSteps` runs.
- [x] `openTimeline(_:)` doc comment updated to "opens an existing timeline."
- [x] No auto-creation path is added.
- [x] Store failure is distinguishable from not found (relates to PKRR-008 —
  landed alongside as `TimelineError.unavailable`).
- [x] All existing tests that sent to un-created UUIDs are updated or explicitly
  expect the typed error.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit); add a lifecycle-invariant suite. Public API change —
audit `Monad`/`Shuttle`/`Yakamoz` send/open paths and follow the downstream-sync
checklist.
