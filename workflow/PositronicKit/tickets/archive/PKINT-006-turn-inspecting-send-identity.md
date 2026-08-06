# PKINT-006 — Give the TurnInspecting Seam a Stable Per-Send Turn Identity

**Priority:** P3
**Type:** API model clarity (leaky abstraction)
**Depends on:** None
**Blocks:** Clean inspector consumers (Yakamoz today, Monad later)
**Surfaced by:** YAK-2 (Yakamoz)
**Status:** Completed 2026-07-04 (`PositronicKit` commit `27c4122`, `Yakamoz` commit `97ce093`)

### Summary

Extend `TurnInspecting` so each composed turn carries a stable identity that distinguishes the
**logical user send** from the **engine round-trip ordinal within that send**, instead of
exposing only a bare incrementing `turnIndex` that consumers must reverse-engineer.

### Current Problem

One user send drives N engine LLM round-trips (one per tool-resolution loop), and each fires
`TurnInspecting.didComposeTurn` with its own incrementing index. The view model tracks one
logical turn per send. YAK-2 reconciled this by writing the response/tool traces to the
engine's *latest* row and decoupling bubble selection from inspection index — a working but
fragile "latest row" reconciliation that every inspector consumer must re-derive. The seam
leaks an internal counter whose mapping to a user-facing send is implicit.

### Files

- Modify: the `TurnInspecting` protocol and its `didComposeTurn`/turn-index types in
  `PositronicKit` (`Services/Chat/` inspection surface) + `PKShared` DTOs if the identity type
  is shared.
- Modify: `ChatEngine` to populate the identity.
- Modify: inspection tests; coordinate with Yakamoz's `SwiftDataTurnInspector` consumer.

### Implementation Requirements

1. Introduce a turn identity that pairs a per-send id (stable across the send's round-trips)
   with a round-trip ordinal (0-based within the send), e.g. `TurnIdentity(sendId: UUID,
   roundTrip: Int)`, and pass it to `didComposeTurn`.
2. Make it trivial for a consumer to answer "which composed turn carries the final response for
   this send?" without a "latest row" heuristic — e.g. mark the terminal round-trip, or expose
   the send's round-trip count.
3. Keep `turnIndex` available (back-compat) but document it as a monotonic engine counter, with
   `TurnIdentity` as the consumer-facing mapping.
4. Transport-neutral and persistence-neutral: the identity is a value type in core/shared, not
   tied to SwiftData or any store.

### Required Tests

- A multi-round-trip send (tool loop) asserts every `didComposeTurn` shares one `sendId` with
  increasing `roundTrip`, and the terminal round-trip is identifiable.
- A reload test asserts a consumer can map a user bubble to the round-trip carrying the
  response + tool traces using the identity alone (no latest-row heuristic), reproducing the
  YAK-2 acceptance scenario against the new API.

### Acceptance Criteria

- [x] `TurnInspecting` exposes a stable per-send identity distinguishing send from round-trip.
- [x] A consumer can locate the response-bearing turn without a "latest row" workaround.
- [x] Existing `turnIndex` semantics remain available and documented.
- [ ] `make verify` green; Yakamoz inspector tests updated and green.

### Landed Notes

- Added `TurnIdentity(sendId: UUID, roundTrip: Int)` and threaded it through `TurnInspection`.
- `ChatEngine` now assigns one stable `sendId` per `execute` call and increments `roundTrip`
  across tool-loop turns while preserving the historical monotonic `turnIndex`.
- Yakamoz's `SwiftDataTurnInspector` now persists `sendId` / `roundTrip`, supports lookups and
  response enrichment by `TurnIdentity`, and `ChatViewModel` uses the terminal send-local
  identity instead of a conversation-wide latest-row heuristic.
- Integration and projection tests were updated to assert stable per-send identity behavior.

### Verification Notes

- Verified locally in `PositronicKit`: `swift test` passed on 2026-07-04, including
  `TurnInspectingTests`.
- Yakamoz-side tests were updated in lockstep, but full `xcodebuild` verification in this
  environment was blocked by package-resolution / simulator-service permission failures.

### Handoff Notes

Coordinate the API shape with the Yakamoz `SwiftDataTurnInspector`/`ChatViewModel` consumer in
the same change — this seam exists primarily to serve inspector UIs, so the consumer's needs
define whether "terminal round-trip flag" or "round-trip count" is the better primitive.
