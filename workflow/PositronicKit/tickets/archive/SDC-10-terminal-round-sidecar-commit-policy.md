---
Priority: P1
Type: Sidecar orchestration / public event API
Depends on: None
Blocks: Reliable self-narrative curation and durable sidecar replay
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: PositronicKit chat runtime
Effort: M
Resolution: Implemented 2026-07-29. PositronicKit `4ab8726` (merged as `8202e05`). Added
terminal-round sidecar commit policy, stable `TurnIdentity`, Codable completion payloads,
terminal-policy tests, examples, and migration documentation. Final merged main verification
passed with 1598 tests in 237 suites. The additive API preserves `.everyRoundTrip` as default;
no persistence migration was required.
---

# SDC-10 — Commit Sidecar Results Only from the Terminal Round Trip

## Summary

Add a per-send sidecar commit policy that preserves today's every-round behavior by default
and optionally emits a committed sidecar completion only for the terminal LLM round trip of a
logical chat send. Include the send/round-trip `TurnIdentity` in the completion payload so
consumers can persist, deduplicate, and replay sidecar outcomes without inferring provenance
from event order.

This is a commit/event-routing policy, not transcript persistence. PositronicKit must continue
to keep sidecar payloads out of persisted conversation messages.

## Current Problem

- `PositronicKit/Sources/PositronicKit/Services/Chat/ChatTurnContext.swift:105-107,153-154`
  stores the same directive list as session configuration and copies it into every internal
  `forTurn` context. A tool-using send therefore requests sidecars on every LLM round trip.
- `PositronicKit/Sources/PositronicKit/Services/Chat/Stages/LLMStreamingStage.swift:204-215`
  writes each round's parsed results into that round's `TurnOutputs` and immediately emits
  `.sidecarsCompleted`, before tool routing or plugin follow-up determines whether another
  round trip will run.
- `PositronicKit/Sources/PositronicKit/Services/Chat/ChatEngine+TurnLoop.swift:61-122`
  decides only after the pipeline completes whether tool results or plugin messages require a
  follow-up round. At the point the current completion event is emitted, terminality is not yet
  known.
- `PositronicKit/Sources/PKShared/SharedTypes/ChatEvent.swift:198,290-292,328-332`
  carries only `[SidecarResult]`; it has no explicit send or round-trip identity.
- `PositronicKit/Sources/PositronicKit/Protocols/PromptObserving.swift:34-43` already defines
  the required `TurnIdentity(sendId:roundTrip:)`, but it lives in the `PositronicKit` target
  while `ChatEvent` lives in `PKShared`. The identity must move to an appropriate shared module
  (and become `Codable`) before a `ChatEvent` payload can use it without reversing module
  dependencies.
- `PositronicKit/Sources/PositronicKit/Services/Chat/Stages/MessagePersistenceStage.swift:75-109`
  persists only extracted response text, reasoning, and tool calls. Sidecar results are not
  stored in PositronicKit conversation history. This is intentional: raw combined JSON and
  directive outputs must not poison later prompts. Yakamoz currently performs separate durable
  storage in `Yakamoz/Sources/YakamozCore/Inspection/InspectionDTOs.swift:136-177`.

For self-narrative or other durable curation, an intermediate result can therefore be mistaken
for the send's final result before the agent has observed tool output or completed plugin-driven
follow-up work. Event order alone is also insufficient for safe idempotency or replay.

## Implementation Requirements

1. Add a public, `Sendable` sidecar commit policy at the `ChatRunRequest` boundary:

   ```swift
   public enum SidecarCommitPolicy: Sendable, Codable, Equatable {
       case everyRoundTrip
       case terminalRoundTrip
   }
   ```

   Thread it through `ChatEngine.prepareSession`, `ChatTurnContext`, and `forTurn`. Default to
   `.everyRoundTrip` so callers that do not opt in retain current commit frequency.

2. Define terminality at the logical-send level, not merely as "this round had no tool calls":

   - discard/buffer a round's completion when tool results cause `.continueWith`;
   - discard/buffer it when `ChatTurnFollowUpPolicy` schedules plugin messages;
   - commit only when the loop will finish normally after the current round;
   - do not promote an intermediate result when the send is cancelled, fails, reaches
     `maxTurns`, or defers an external tool without a final post-tool LLM round.

   `TurnOutputs` may retain the candidate results until `runChatLoop` makes this decision. Do
   not persist candidates in `MessageStoreProtocol` or append them to prompt history.

3. Under `.everyRoundTrip`, preserve the existing behavior of one committed completion per
   successfully parsed round trip. Under `.terminalRoundTrip`, emit exactly one committed
   completion for a normally completed logical send, from its terminal round trip.

4. Include `TurnIdentity(sendId: context.sendId, roundTrip: context.turnCount - 1)` in every
   committed completion event. Move/generalize `TurnIdentity` into `PKShared` so both
   `PromptInspection` and `ChatEvent` share one canonical type; add `Codable` conformance and
   Codable round-trip coverage.

5. Prefer a named completion payload (for example `SidecarCompletion`) over an expanding
   positional tuple, containing `identity` and `results`. Keep consumer ergonomics via
   computed accessors for both the full completion and result-only projection.

6. Treat `.delta(.sidecar)` as uncommitted streaming observation. Document that durable side
   effects and persistence must be triggered only by the identified completion payload. The
   terminal policy may buffer/suppress intermediate deltas if needed, but must not present an
   intermediate delta as committed.

7. Preserve the conversation-history invariant: `ConversationMessage.content` contains only
   the extracted user-visible response, and neither raw combined JSON nor `SidecarResult`
   values are added to the transcript. Durable self-narrative storage remains a consumer-owned
   persistence concern driven by the committed event.

8. This changes a public `ChatEvent` associated payload and can break exhaustive switches.
   Update `CHANGELOG.md` under Unreleased, document the source migration, and choose the
   appropriate semver release line before downstream pin bumps.

9. Audit all consumers explicitly:

   - **Monad:** update `MonadCLI/ChatREPL+Streaming.swift` and any HTTP/SSE event projections;
     run `swift test` with the released compatible PositronicKit pin.
   - **Shuttle:** audit `ShuttleShardAgentRunner` and all `ChatEvent` switches even though it
     does not currently consume sidecars; run `swift test` with the released compatible pin.
   - **Yakamoz:** update `ChatEventReducer`, `ChatViewModel`, inspector DTO persistence, and
     sidecar tests to consume the event's explicit identity rather than event ordering; run
     `make verify` with the released compatible pin.

   Use the documented local-path overrides while developing the unreleased public API. No
   Monad GRDB migration is expected because this ticket does not add a persisted PK model
   field, but explicitly verify `DatabaseSchema+Migrations.swift` remains unaffected.

## Acceptance Criteria

- [ ] A regression test with at least one tool-call round proves current every-round sidecar
      candidates exist and `.terminalRoundTrip` exposes only the final post-tool result.
- [ ] A plugin-follow-up test proves a pre-follow-up no-tool round is not committed as terminal.
- [ ] `.everyRoundTrip` remains the default and emits an identified completion for each round.
- [ ] `.terminalRoundTrip` emits exactly one identified completion on normal completion.
- [ ] Cancellation, provider failure, `maxTurns`, and external-tool deferral do not commit a
      non-terminal candidate.
- [ ] Completion identity uses one stable `sendId` and the correct zero-based `roundTrip`.
- [ ] `TurnIdentity` and the new completion payload round-trip through `Codable`.
- [ ] Persisted PositronicKit assistant messages contain only extracted response text and no
      sidecar result/raw JSON fields.
- [ ] PositronicKit examples and usage docs demonstrate terminal-round curation and
      idempotent persistence keyed by `TurnIdentity`.
- [ ] `CHANGELOG.md` includes the API change and source-migration note.
- [ ] `make verify` passes in PositronicKit with tests confirmed to execute.
- [ ] Monad, Shuttle, and Yakamoz consumer audits and released-pin verification results are
      recorded before the ticket is closed.
