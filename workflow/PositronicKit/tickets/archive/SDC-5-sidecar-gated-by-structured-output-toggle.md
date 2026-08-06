# SDC-5 — Gate sidecar directives behind the existing structured-output enablement

**Status:** Done (PK landed in `PositronicKit/main` on 2026-07-04; the Yakamoz follow-up is
absorbed into `workflow/Yakamoz/tickets/SID-1-title-directive-with-cadence.md` rather than
tracked here, since there is no sidecar directive to gate until SID-1 lands — see that ticket's
"Toggle plumbing (from SDC-5)" item)
**Severity:** 🟡 Medium (feature gating / UX consistency)
**Repos:** PositronicKit + Yakamoz
**Source:** 2026-07-03 follow-up discussion

## Problem

Piggy-backed requests must be switchable without introducing a new setting. The workspace
already has exactly one user-facing structured-output enablement: Yakamoz's per-conversation
**Typed Replies** toggle (`ConversationModel.typedReplyEnabled`, UI in
`Yakamoz/Sources/Yakamoz/Views/TypedReplyControls.swift`; consumed by `ChatViewModel` /
`YakamozRuntime` via `TypedReply`). Sidecar directives ride the same structured-output
machinery, so they should ride the same switch: toggle off → plain streaming turn, no combined
schema, no sidecar events.

PositronicKit itself has no persistent settings store — enablement is parameter-driven
(`executeTurn(sidecars:)`); the gate belongs at the consumer boundary, but PK should make the
"disabled" path first-class rather than every consumer re-implementing it.

## Suggested direction

1. **PK:** `executeTurn(sidecars: [])` (or nil) must be an exact no-op relative to today's
   behavior — no schema composition, no `SidecarExtractionStage` in the pipeline, no new event
   emissions. Add a test pinning this (event-stream equality with a baseline turn).
2. **PK:** add a convenience on the turn-building path (e.g. `sidecarsIfEnabled(_:when:)` or a
   documented pattern in `PositronicKitExamples`) so consumers express "these directives, but
   only when structured output is enabled" in one place.
3. **Yakamoz:** derive sidecar activation from `typedReplyEnabled` — when the toggle is off,
   the coordinator passes no sidecars; when on, the per-turn directive policy (title cadence
   etc., SDC-6) decides which directives ride. The existing `.task(id:)` rebuild in `ChatView`
   already picks up flag changes.
4. Inspector: when the toggle is off, the sidecar inspector section shows nothing (not an
   error state).

Tests: Yakamoz reducer/coordinator tests for both toggle states; PK no-op pinning test.

## Completion note

The PositronicKit half is done: the exact no-sidecar runtime path is pinned and the facade now
exposes `sidecarsIfEnabled(_:when:)` as the shared consumer seam. The Yakamoz toggle wiring and
its reducer/coordinator coverage are still downstream work.
