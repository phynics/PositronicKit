# PKV3-003 — Replace Conversation with TimelineDriver

**Priority:** P1
**Type:** Breaking API / interaction
**Depends on:** —
**Blocks:** PKV3-006
**Triage:** ready-for-agent
**Status:** Done (2026-07-13, PositronicKit branch `pkv3-track2-workspace-timeline` commit `9e5e7fa`)

**Resolution:** Deleted `Conversation` and its vending methods (`PositronicKit.newConversation(title:)`,
`PositronicKit.conversation(timelineId:)`). Added `TimelineDriver` (`timelineID`, `send(_:)`,
`cancel()`, no mutable turn state, no exposed `TimelineManager`) and
`PositronicKit.openTimeline(_:)` as pure driver construction — persistence happens lazily on the
first `send(_:)`, same as before. Renamed `PKObservable.ObservableConversation` →
`TimelineController` (`.conversation` property → `.driver`), superseding-send behavior unchanged.
Migrated all Sources/Tests/docs/examples references. Added `TimelineDriverTests` (including
"opening does not persist a timeline" / "opening returns fresh handles ... with no persistence
I/O") and updated `TimelineControllerTests` (including "a superseding send cancels the previous
stream") — both verified passing. CHANGELOG updated under Unreleased. `swift build` clean,
`swift test` 950/950 passing (163 suites). **Not yet merged to PositronicKit `main`** — Track 2 of
the parallel PKV3 batch; integration happens via PKV3-006 after all three tracks close.

## Summary

Replace the Conversation cursor with TimelineDriver: a lightweight, stable value that sends and cancels work for exactly one durable Timeline.

## Current Problem

- `Conversation.swift` names a second interaction concept over the persisted Timeline record.
- `ObservableConversation` mirrors its cursor, spreading conversation/session vocabulary through SwiftUI, tests, examples, and documentation.

## Implementation Requirements

- Delete Conversation and its vending methods.
- Add `TimelineDriver` with `timelineID`, `send(_:)`, and `cancel()`; it has no mutable turn state, persistence lookup, or exposed TimelineManager.
- Add `PositronicKit.openTimeline(_:)` as pure driver construction.
- Rename `ObservableConversation` to `TimelineController`, retaining UI projection and superseding-send behavior.
- Remove runtime session/conversation wording; provider SDK session names may remain local.

## Acceptance Criteria

- [ ] Opening a TimelineDriver performs no persistence I/O.
- [ ] TimelineDriver sends through the canonical turn path and delegates cancellation correctly.
- [ ] TimelineController mirrors stream state without reintroducing Conversation.
- [ ] Package/docs/examples/consumers contain no old runtime conversation/session vocabulary.

