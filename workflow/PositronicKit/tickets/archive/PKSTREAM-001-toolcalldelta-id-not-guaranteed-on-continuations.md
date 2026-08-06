# PKSTREAM-001 — `ToolCallDelta.id` is nil on OpenAI-style continuation chunks; no ID-bearing final delta is ever guaranteed

**Priority:** P2
**Type:** Bug (streaming event contract)
**Depends on:** none
**Blocks:** none
**Status:** Done
**Source:** Yakamoz UIX-5 (`workflow/Yakamoz/tickets/archive/UIX-5-tool-call-arguments-sometimes-missing.md`), user report 2026-07-05 via `openrouter/free`

## Summary

`LLMStreamingStage.handleToolCallDeltas` (`Sources/PositronicKit/Services/Chat/Stages/LLMStreamingStage.swift:232-253`)
forwards each provider tool-call chunk's `id` field verbatim into the `ChatEvent.delta(.toolCall(ToolCallDelta))`
stream it yields to consumers:

```swift
private func handleToolCallDeltas(
    _ result: LLMStreamChunk,
    context: ChatTurnContext,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
) async {
    guard let calls = result.choices.first?.delta.toolCalls else { return }
    for call in calls {
        guard let index = call.index else { continue }
        await context.outputs.accumulateToolCall(
            index: index, id: call.id, name: call.function?.name, args: call.function?.arguments
        )
        continuation.yield(.toolCall(ToolCallDelta(
            index: index, id: call.id, name: call.function?.name, arguments: call.function?.arguments
        )))
    }
}
```

OpenAI-style streaming (confirmed via OpenRouter's `openrouter/free` routing) emits the tool call's
`id` only on the **first** chunk for a given `index`; every continuation chunk carries the same
`index` with `id == nil`. `ToolCallDelta` (`Sources/PKShared/SharedTypes/ChatAPITypes.swift:7-23`)
does have an `index: Int` field precisely to let consumers stitch these back together — but
`handleToolCallDeltas` does **not** backfill `call.id` from `context.outputs`'s own accumulator
(which it *does* correctly key by `index` via `accumulateToolCall(index:id:...)`) before yielding
the public event. Every yielded `ToolCallDelta` for a continuation chunk is therefore `id: nil`,
even though the engine's own internal accumulator (`context.outputs.toolCallAccumulators`, consumed
later by `ToolCallExtractionStage`) knows the correct id for that index the whole time.

There is **no later, ID-bearing "final" delta** guaranteed on this path: the next event for that
tool call after the continuation chunks is a `.toolExecution`/`.toolCompleted` status event with
the id already resolved server-side — never another `.toolCall` delta. The doc comment previously
in Yakamoz's reducer ("the engine later emits an ID-bearing final delta before executing tools")
does not describe any code path that actually exists in `LLMStreamingStage`; it was a plausible-sounding
but unverified assumption. Confirmed by reading `ToolCallExtractionStage.swift:21-104`: that stage only
consumes `context.outputs.toolCallAccumulators` (already correctly keyed) and, in the *no-structured-calls*
fallback path (`accumulators.isEmpty`), yields `ToolCallDelta`s with real ids — but that fallback path
does not run when structured calls *were* accumulated, which is the normal streaming case that hits
this bug.

Additionally: `ToolExecutionStatus`'s cases (`Sources/PKShared/SharedTypes/ChatEvent.swift:4-9` —
`.attempting(name:reference:)`, `.success(ToolResult)`, `.failed(reference:error:)`, `.failure(String)`)
and `ToolResult` (`Sources/PKShared/SharedTypes/ToolResult.swift:4-19` — `success`, `output`, `error`)
carry **no arguments field anywhere**. So a consumer that misses the streamed arguments has no way
to recover them from execution-status/completion events either — the only recoverable source of
truth for a tool call's arguments is the streamed `.toolCall` delta sequence itself, which makes
getting delta emission right the *only* fix surface, not a "belt-and-braces" fallback.

## Current Problem (impact)

Any consumer that projects `ChatEvent.toolCall` deltas for live UI (matching id → accumulating
arguments) and drops id-less deltas — which is the reasonable naive implementation, since `id`
looks like the natural accumulation key — silently loses all argument text after the first chunk.
Yakamoz hit this exactly (`ChatTurnState.applyToolCallDelta`,
`Yakamoz/Sources/YakamozCore/Chat/ChatEventReducer.swift`, pre-fix ~line 177-193): a succeeded
`cat` call rendered as `cat()` in the transcript despite executing with a real path argument,
because only the first (often empty-argument) chunk carried an id and every continuation was
dropped.

Yakamoz worked around this locally (index→id routing in the reducer, since `ToolCallDelta.index`
is public and stable per call) — see the Yakamoz-side fix landed for UIX-5. This ticket is to fix
the actual gap in PositronicKit so every consumer gets a correct id on every delta, rather than
requiring each consumer to re-implement index-based id backfilling.

## Implementation Requirements

- In `LLMStreamingStage.handleToolCallDeltas`, after calling `context.outputs.accumulateToolCall(index:id:name:args:)`,
  read back the accumulator's resolved id for that `index` (the accumulator already stores it
  correctly-keyed) and use *that* resolved id — not the raw per-chunk `call.id` — when constructing
  the yielded `ToolCallDelta`. This guarantees every yielded delta for a given index carries the
  same, correct, non-nil id from the first chunk onward, with no behavior change to the accumulator
  itself or to `ToolCallExtractionStage`.
- Add/extend provider-adapter or `LLMStreamingStage` tests (see `Tests/PositronicKitTests/ChatEnginePipelineTests.swift`,
  `Tests/PositronicKitTests/ToolCallRegressionTests.swift`, `Tests/PKTestSupport/ChatStreamResultFactory.swift`
  for existing chunk-factory helpers) covering: an id-bearing first chunk followed by id-less
  continuation chunks at the same index — assert every yielded `ChatEvent.toolCall` delta has the
  same non-nil `id`.
- Multiple parallel tool calls interleaved by index (0, 1, 0, 1, ...) must each resolve to their own
  correct id, not cross-contaminate.
- This is a `PositronicKit`-internal behavior fix — `ToolCallDelta`'s public shape does not change,
  so it is source- and binary-compatible; no consumer migration required beyond picking up the new
  release. Still, per the workspace downstream-sync checklist, grep Monad/Shuttle/Yakamoz for any
  code relying on the *current* (buggy) nil-on-continuation behavior before closing — none is
  expected (Yakamoz's UIX-5 fix is defensive/correct either way and should not be reverted, since it
  is also the correct behavior for any older pinned PositronicKit release Yakamoz might still run
  against).

## Acceptance Criteria

- [x] `LLMStreamingStage.handleToolCallDeltas` yields a non-nil, correct `id` on every `.toolCall`
      delta for a tracked index, including continuation chunks.
- [x] New tests cover: id-bearing-first + id-less-continuations (single call), and interleaved
      parallel calls by index.
- [x] `make verify` green in PositronicKit.
- [x] Consumers (Monad, Shuttle, Yakamoz) checked for reliance on the old nil-id behavior; none
      expected to need changes since they either don't consume `.toolCall` deltas directly or (Yakamoz)
      already tolerate id-less continuations defensively.
- [x] Ticket closed with a note on which PositronicKit release first ships the fix, so consumers can
      track the repin in their own changelogs.

## Resolution (2026-07-05)

Fixed in `LLMStreamingStage.handleToolCallDeltas`
(`Sources/PositronicKit/Services/Chat/Stages/LLMStreamingStage.swift:232-256`): after
`context.outputs.accumulateToolCall(index:id:name:args:)`, the handler now reads back
`context.outputs.toolCallAccumulators[index]?.callId` and uses that resolved id (not the raw
per-chunk `call.id`) when constructing the yielded `ToolCallDelta`. Every delta for a tracked
index — including id-less continuation chunks — now carries the same non-nil id from the first
chunk onward. No change to the accumulator or to `ToolCallExtractionStage`; `ToolCallDelta`'s
public shape is unchanged (source/binary compatible).

Tests added in `Tests/PositronicKitTests/ChatEnginePipelineTests.swift`
(`LLMStreamingStageBehavior` suite):
- `toolCallDeltaIdIsBackfilledOnContinuationChunks` — id-bearing first chunk + two id-less
  continuation chunks at index 0; asserts all 3 emitted `.toolCall` deltas carry `id == "tc-1"`
  and that `arguments` joined across all three deltas equals the full accumulated JSON.
- `interleavedParallelToolCallDeltasResolveOwnIdsWithoutCrossContamination` — two parallel tool
  calls interleaved by index (0, 1, 0, 1); asserts index-0 deltas all resolve `id == "tc-1"` and
  index-1 deltas all resolve `id == "tc-2"`, no cross-contamination.

Both new tests failed before the fix (raw `nil` ids on continuation chunks) and pass after.
`make verify` from `PositronicKit/`: green, 750 tests executed across 139 suites (nonzero —
confirmed not the zero-executed-tests trap).

Downstream-sync grep (Monad, Shuttle, Yakamoz) for `ToolCallDelta` consumption:
- `Monad/Sources/MonadCLI/ChatREPL+Streaming.swift:169-176` — accumulates args keyed by
  `delta.id` only when non-nil; does not itself backfill id-less continuations by index, so it
  was already tolerant of (not reliant on) the old nil-id behavior and gains more complete
  argument capture for free now that every delta carries the resolved id. No change needed.
- `Yakamoz/Sources/YakamozCore/Chat/ChatEventReducer.swift:199-226`
  (`ChatTurnState.applyToolCallDelta`, the UIX-5 fix) — explicitly routes id-less deltas by
  `index` to the first-seen id; this is defensive and correct against both the old and new
  behavior, and per the ticket must not be reverted. Left untouched.
- No other production call sites consume `.toolCall`/`ToolCallDelta` directly in Monad, Shuttle,
  or Yakamoz (only test fixtures/support files reference the type).

This fix ships in the next tagged PositronicKit release after `1.0.0`. No tag/release/repin was
performed as part of this ticket — that step remains for the maintainer per `PKPOST-002`
(release process and cadence). Consumers should track the repin via their own changelogs once
that release lands.
