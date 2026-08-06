# PKINT-004 — Promote the Stream Watchdog to a Production Default and Surface Empty-but-Finished Completions

**Priority:** P2
**Type:** Robustness / observability defect
**Depends on:** None
**Blocks:** Reliable failure surfacing for every consumer
**Surfaced by:** YAK-23, YAK-24 (Yakamoz)
**Status:** Completed 2026-07-04 (`PositronicKit` commit `27c4122`)

### Summary

Ensure the per-stream watchdog in `LLMStreamingStage` is actually in force in the production
composition path (not merely defaulted in the stage initializer), and add a distinct,
observable outcome for a turn that finishes with **no content and no tool call**, so an empty
completion surfaces as a recognizable event rather than an indistinguishable empty assistant
bubble.

### Current Problem

YAK-23 added a watchdog: `LLMStreamingStage` takes `streamTimeout: TimeInterval = 60` and
throws `ChatEngineError.streamTimedOut` (`Sources/PositronicKit/Services/Chat/Stages/LLMStreamingStage.swift:10,59`).
Two gaps remain:

1. The 60s default lives in the stage initializer. Confirm the production wiring
   (`PositronicKit` composition / `ChatEngine.Dependencies`) actually constructs the stage
   with a deliberate timeout and that the value is configurable, rather than relying on the
   implicit default being threaded everywhere. A consumer that builds the pipeline directly
   must not accidentally get an unbounded stream.
2. YAK-24 (surface empty model response) is a real product gap with a core component: when a
   provider returns HTTP 200 with empty content and no tool call (the DeepSeek/Qwen behavior
   observed in YAK-23), the engine yields an empty assistant message with no signal. There is
   no `ChatEvent` distinguishing "the model finished and said nothing" from "still streaming".

### Files

- Modify: `Sources/PositronicKit/Services/Chat/Stages/LLMStreamingStage.swift`
- Modify: `Sources/PositronicKit/Services/Chat/ChatEngine.swift` (where the turn completes)
- Modify: `Sources/PositronicKit/PositronicKit.swift` and/or `ChatEngine.Dependencies` (make
  the timeout an explicit, documented production default and configurable).
- Modify: the `ChatEvent` definition in `PKShared` if a new event/flag is added.

### Implementation Requirements

1. Make the production composition path construct `LLMStreamingStage` with an explicit,
   documented timeout (configurable via `GenerationParameters` or a runtime option), defaulting
   to the current 60s. Document that constructing the pipeline without a timeout is not a
   supported configuration.
2. When a turn completes with empty reconstructed text **and** zero tool calls **and** a
   present `finishReason`, emit a distinct signal (a `ChatEvent` case/flag, e.g.
   `.completedEmpty(finishReason:)`) so consumers can show "the model returned an empty
   response" instead of a blank bubble. Do not throw — an empty completion is a valid (if
   useless) provider outcome, distinct from a timeout.
3. Keep `streamTimedOut` for the never-terminates case; keep it as a thrown pipeline error.
4. Back-compatible: existing consumers that ignore the new event still behave as today (blank
   assistant text), just without the new affordance.

### Required Tests

- A scripted `MockLLMService` whose stream never finishes asserts the run errors with
  `streamTimedOut` after the configured timeout (extend the existing post-tool follow-up test
  to also cover a first-round stall).
- A scripted completion with empty content + no tool calls + `finishReason: "stop"` asserts the
  new empty-completion event/flag is emitted and the run finishes cleanly (no error).
- A test asserts the production composition path uses a bounded timeout (the stage is not
  constructed with an infinite/absent timeout).

### Acceptance Criteria

- [x] The production pipeline always runs with a bounded, configurable stream timeout.
- [x] An empty-but-finished completion is observably distinct from an in-progress stream and
      from a timeout.
- [x] A never-terminating stream surfaces `streamTimedOut` in core, for every consumer.
- [ ] `make verify` green; Monad/Shuttle build; Yakamoz `make verify` green.

### Landed Notes

- `ChatEngine.Dependencies` now owns the documented production default stream timeout and threads
  it explicitly into `ChatTurnPipelineBuilder` / `LLMStreamingStage`.
- `ChatEvent.CompletionEvent.completedEmpty(finishReason:)` now surfaces empty-but-finished model
  completions without throwing, and `MessagePersistenceStage` emits it only for the no-tool-call
  terminal path.
- Coverage landed in `ChatEngineTests`, `ChatEnginePipelineTests`, and `ChatEventTests`.

### Verification Notes

- Verified locally in `PositronicKit`: `swift test` passed on 2026-07-04.
- Downstream `Monad`/`Shuttle`/`Yakamoz` verification was attempted but blocked by this
  environment's SwiftPM/Xcode sandbox/cache permissions before the consumers reached normal
  package resolution / build execution.

### Verification

```bash
swift test --filter LLMStreamingStage
swift test --filter ChatEngine
make verify
```

### Handoff Notes

YAK-23's empty-completion symptom was originally misdiagnosed as a hang. Distinguishing the
two outcomes in core (timeout vs. legitimately-empty) is what lets every consumer give the
user a correct message without re-deriving the distinction.
