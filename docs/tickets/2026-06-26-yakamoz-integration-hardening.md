# Yakamoz Integration Hardening Follow-up Tickets

These tickets turn the **point fixes** discovered while integrating `PositronicKit` into
the Yakamoz showcase app (the `YAK-*` series in `../../../Yakamoz/docs/tickets/`) into
**durable, transport-neutral contracts** in the shared runtime. Each `YAK-*` bug was fixed
at one call site or one provider; the integration review showed every one of them is the
visible instance of a *class* of latent defect that the next consumer (Monad, Shuttle, or a
second provider) can re-trip. The theme across all of them: **PositronicKit's contracts do
not fail loudly, and several were corrected in one place but not generalized.**

Scope is restricted to `PositronicKit` (core runtime + provider adapters + shared types).
Yakamoz-only UX work (markdown rendering, model switcher, timeline dots) and the
app-target/framework linker-boundary mirror types are **out of scope** — the latter is a
consumer packaging choice, not a runtime defect, and is tracked downstream.

Priority order: **PKINT-001** and **PKINT-002** are P1 correctness blockers (silent data
loss / silent request corruption). **PKINT-003**, **PKINT-004**, **PKINT-005** are P2
robustness/ergonomics. **PKINT-006** and **PKINT-007** are P3 model-clarity follow-ups.

Per the workspace cross-repo convention, every ticket that changes a public `PositronicKit`
API must update `PositronicKitExamples`, the relevant tests, and the `Monad`/`Shuttle`/
Yakamoz call sites in the same change, and keep `make verify` green.

**Breaking changes are acceptable for this set.** Where a clean break and a back-compat shim
both solve a ticket, prefer the clean break and migrate every in-workspace call site in the
same change — there are no external `PositronicKit` consumers to preserve. Do not keep
deprecated shims solely to avoid touching `Monad`/`Shuttle`/Yakamoz.

---

## PKINT-001: Make snake_case-Safe Stream Decoding a Provider Contract, Not a Per-Provider Patch

**Priority:** P1
**Type:** Correctness defect (silent data loss)
**Depends on:** None
**Blocks:** Any new streaming provider; reliable tool calling on every provider
**Surfaced by:** YAK-23 (Yakamoz)

### Summary

Establish a single, enforced contract that **every** streaming provider adapter decodes the
on-wire SSE payload into `LLMStreamChunk` without silently dropping fields, and back it with
a shared golden-wire conformance suite seeded from captured raw provider chunks. Today only
`PKOpenRouterProvider` has the fix and a regression test; the same defect can re-form in
`PKOpenAIProvider`, `PKOllamaProvider`, and any future adapter.

### Current Problem

The `LLMStreamChunk` family is camelCase with **no explicit `CodingKeys`**, while provider
wire formats are snake_case (`tool_calls`, `finish_reason`). YAK-23 proved that a plain
`JSONDecoder()` therefore decodes `tool_calls`/`finish_reason` to `nil` on every chunk — so
**every streamed tool call is silently discarded** and the response looks like an empty
completion, not an error.

That was fixed for exactly one provider:

- `Sources/PKOpenRouterProvider/OpenRouterClient.swift:210-216` now sets
  `decoder.keyDecodingStrategy = .convertFromSnakeCase`, with a captured-wire regression test.

The other adapters are unaudited against the same failure mode:

- `PKOpenAIProvider` decodes via the SDK's typed model mapped through
  `OpenAIConversions.toLLMStreamChunk()` (`Sources/PKOpenAIProvider/OpenAIConversions.swift:71`).
  This *probably* avoids the raw-JSON pitfall, but there is **no test** that proves a real
  OpenAI tool-call SSE chunk survives the mapping into a non-nil `toolCalls`/`finishReason`.
- `PKOllamaProvider` uses bare `JSONDecoder()` in multiple decode paths
  (`Sources/PKOllamaProvider/OllamaClient.swift:127`, `Sources/PKOllamaProvider/OllamaModels.swift:127`).

There is no shared contract test, so the next adapter (or a refactor of an existing one)
re-introduces the bug with zero signal.

### Files

- Add: `Tests/PositronicKitTests/Providers/StreamDecodingConformanceTests.swift` (or the
  established provider-test location) — a shared, fixture-driven suite.
- Add: `Tests/PositronicKitTests/Providers/Fixtures/` — captured raw SSE chunks (one per
  provider) containing a streamed tool call with `tool_calls` + `finish_reason: "tool_calls"`.
- Audit/modify: `Sources/PKOpenAIProvider/OpenAIClient.swift`, `Sources/PKOpenAIProvider/OpenAIConversions.swift`
- Audit/modify: `Sources/PKOllamaProvider/OllamaClient.swift`, `Sources/PKOllamaProvider/OllamaModels.swift`
- Reference (already fixed, keep as the template): `Sources/PKOpenRouterProvider/OpenRouterClient.swift:210-216`

### Implementation Requirements

1. Define the contract in one place: any decode that targets `LLMStreamChunk` (or its nested
   delta/tool-call/usage types) must either use `.convertFromSnakeCase` or declare explicit
   `CodingKeys` that map every wire field. Pick **one** mechanism per type and document it at
   the type definition so future fields inherit it.
2. Prefer fixing it at the `LLMStreamChunk` type boundary (explicit `CodingKeys` on the shared
   types in `PKShared`) over relying on each adapter to remember a decoder flag, so a provider
   that forgets the flag still decodes correctly. If explicit keys are impractical for a type,
   the conformance test (below) is the backstop.
3. Audit each provider's streaming path and make it satisfy the contract. Do not change any
   provider's successful output shape for plain-text streaming (which already worked because
   `content`→`content` needs no conversion).
4. Do not introduce `.convertFromSnakeCase` on a decoder that also reads a type with an
   intentional snake_case wire key that would now double-convert — verify each decoder's full
   payload, not just the chunk type.

### Required Tests

- For **each** streaming provider, a fixture-driven test feeds a captured raw tool-call SSE
  chunk through the real decode path and asserts the resulting `LLMStreamChunk` has a non-nil
  tool call (id, name, arguments) and the expected `finishReason`.
- A test asserts a plain-text chunk still decodes to the expected `content` for each provider
  (guards against a double-conversion regression).
- A "new provider" guard: a table-driven test that fails if a provider adapter is added to the
  package without a corresponding stream-decoding fixture entry (or document this as a review
  checklist item if a compile-time guard is impractical).

### Acceptance Criteria

- [ ] Every streaming provider has a captured-wire test proving `tool_calls` and
      `finish_reason` survive decode into a non-nil `LLMStreamChunk`.
- [ ] The snake_case/CodingKeys contract is documented at the `LLMStreamChunk` type, not only
      in one provider's comment.
- [ ] Plain-text streaming output is byte-for-byte unchanged for all providers.
- [ ] `make verify` green in PositronicKit; `Monad`/`Shuttle` build; Yakamoz `make verify` green.

### Verification

```bash
swift test --filter StreamDecodingConformanceTests
make verify
```

### Handoff Notes

The original YAK-23 investigation burned hours blaming the model and the request payload
before capturing raw SSE proved the decoder ate a valid tool call. The whole point of this
ticket is that "the test passes" for plain text is **not** evidence the tool-call path works —
the fixtures must be real captured tool-call chunks, not hand-written happy-path JSON.

---

## PKINT-002: Validate tool_call ↔ tool_result Pairing During History Reconstruction

**Priority:** P1
**Type:** Correctness defect (silent request corruption → provider 400)
**Depends on:** None
**Blocks:** Multi-turn tool conversations across providers
**Surfaced by:** YAK-26 (Yakamoz)

### Summary

Add an explicit invariant to `ChatEngine`'s history reconstruction: before a request is
issued, every assistant `tool_calls` entry must have a matching tool-result message (and vice
versa). A violation must raise a typed `ChatEngineError`, not be shipped to the provider as a
malformed request that 400s with a provider-specific string.

### Current Problem

YAK-26's root cause — `ToolCall.id` coerced `UUID(uuidString:) ?? UUID()`, regenerating a
random id on every reload — is fixed: `ToolCall.id` is now `String`
(`Sources/PKShared/SharedTypes/ToolCall.swift:9`) and reconstruction at
`Sources/PositronicKit/Services/Chat/ChatEngine.swift:415` preserves the provider id.

But the engine still has **no guard** that the reconstructed message array is internally
consistent. Any future bug in persistence, envelope round-trip, or a new provider's id
handling re-produces the same orphaned-`tool_call` shape, and the only signal is the
provider's HTTP 400 (`"No tool output found for function call <id>"`) — opaque, provider-
specific, and surfaced to the end user instead of caught in the runtime.

### Files

- Modify: `Sources/PositronicKit/Services/Chat/ChatEngine.swift` (around `makeHistoryMessage`,
  line ~396, and wherever the per-turn message array is finalized before the LLM call).
- Modify: `Sources/PositronicKit/Services/Chat/...` `ChatEngineError` definition (add a case).
- Modify: the corresponding `ChatEngine`/history reconstruction test file.

### Implementation Requirements

1. After reconstructing the message array for a turn and before issuing the LLM request,
   verify the pairing invariant: the set of assistant `tool_calls` ids equals the set of
   `tool_call_id`s on following tool-result messages (scoped to the same assistant turn).
2. On violation, throw a typed `ChatEngineError.danglingToolCall(id:)` (or
   `.inconsistentToolHistory`) whose `userFriendlyMessage` explains the conversation has an
   unmatched tool call — do **not** issue the request.
3. Keep the check O(n) over the turn's messages; do not re-fetch from persistence.
4. The check must be provider-agnostic (it runs in core, before adapter serialization), so it
   protects every provider uniformly.
5. Do not silently "repair" by dropping the orphaned tool_call — that hides a real persistence
   bug. Fail loudly; repair is a separate, explicit decision.

### Required Tests

- Reconstruct a history containing an assistant `tool_calls` entry with **no** matching
  tool-result and assert the run fails with the typed error before any provider call.
- Reconstruct a well-formed tool history (assistant tool_call + matching tool result) twice
  (simulating reload) and assert it passes the invariant both times and the ids are stable and
  equal to the original provider id (the YAK-26 acceptance test, now asserting the *guard*
  rather than only the decoder).
- A mock-provider test asserting the engine never reaches the provider when the invariant fails.

### Acceptance Criteria

- [ ] A reconstructed history with an unmatched tool_call fails with a typed `ChatEngineError`
      before any network call.
- [ ] A well-formed tool history passes the invariant across repeated reloads with stable ids.
- [ ] The error's `userFriendlyMessage` is actionable and provider-neutral.
- [ ] `make verify` green; Monad/Shuttle build; Yakamoz `make verify` green.

### Verification

```bash
swift test --filter ChatEngine
make verify
```

### Handoff Notes

This is defense-in-depth on top of the `ToolCall.id` fix, not a replacement for it. The value
is converting a provider-specific 400 that reaches the user into a typed runtime error caught
in CI by the round-trip test.

---

## PKINT-003: Guarantee No Provider Round-Trip for an Empty Retrieval Corpus

**Priority:** P2
**Type:** Performance / cost defect
**Depends on:** None
**Blocks:** Acceptable first-send latency for any consumer without a populated memory store
**Surfaced by:** YAK-25 (Yakamoz)

### Summary

Generalize YAK-25's `hasAnyMemory()` preflight into a stated guarantee — *the context
pipeline issues zero provider LLM round-trips when there is nothing to retrieve* — and cover
**every** stage that can make a model call (not only `MemoryRetrievalStage`), with a
regression test that asserts the provider is never called on an empty corpus.

### Current Problem

YAK-25 found `MemoryRetrievalStage` issued its own LLM call (tag generation) on every send,
before checking whether any memory corpus existed — 2–9.7s of latency on an empty
conversation. The fix added `MemoryStoreProtocol.hasAnyMemory()`
(`Sources/PositronicKit/Services/Database/MemoryStoreProtocol.swift:11`) and short-circuited
that one stage (`Sources/PositronicKit/Services/Context/Pipeline/Stages/MemoryRetrievalStage.swift:82`).

What is missing is a **guarantee** and its test. Other pipeline stages
(`ContextAssemblyStage`, ranking, any future retrieval stage) are not asserted to be cheap on
an empty corpus, and nothing prevents a future stage from re-introducing an eager round-trip.
The defect class — "a pipeline stage does expensive provider work before checking it has
anything to work on" — is unguarded.

### Files

- Audit: `Sources/PositronicKit/Services/Context/Pipeline/Stages/` (all stages).
- Modify if any stage makes an unconditional provider call: the offending stage(s).
- Add: a pipeline-level regression test asserting zero provider calls on an empty corpus.

### Implementation Requirements

1. Audit every context/memory pipeline stage for provider/LLM or embedding calls; gate each
   behind a cheap precondition (empty store / below-threshold corpus) consistent with the
   `hasAnyMemory()` pattern.
2. Where a cheap preflight does not already exist for a resource a stage consumes, add one to
   the relevant protocol (mirroring `hasAnyMemory()`), with a default implementation so
   existing conformers are unaffected.
3. Preserve all non-empty retrieval behavior exactly, including injected/mock stores with
   semantic results.
4. Prefer running independent cheap stages concurrently with prompt assembly where the
   existing structure allows, but correctness of the short-circuit is the requirement; the
   concurrency is optional.

### Required Tests

- A pipeline test with an empty memory/vector store asserts the injected mock provider records
  **zero** chat/embedding calls during context assembly, and `Context gathered` work is
  sub-threshold.
- A pipeline test with a populated store asserts retrieval behavior (tag generation, semantic
  matches) is unchanged from current.

### Acceptance Criteria

- [ ] No context/memory pipeline stage issues a provider or embedding call when its corpus is
      empty.
- [ ] A regression test asserts zero provider calls on an empty corpus at the pipeline level
      (not just one stage).
- [ ] Non-empty retrieval behavior is unchanged.
- [ ] `make verify` green; Monad/Shuttle build.

### Verification

```bash
swift test --filter ContextManagerTests
swift test --filter MemoryStoreWiringTests
make verify
```

### Handoff Notes

The existing single-stage fix is correct; this ticket is about the *guarantee* and the
*test that defends it*, so the cost regression cannot silently come back through a different
stage.

---

## PKINT-004: Promote the Stream Watchdog to a Production Default and Surface Empty-but-Finished Completions

**Priority:** P2
**Type:** Robustness / observability defect
**Depends on:** None
**Blocks:** Reliable failure surfacing for every consumer
**Surfaced by:** YAK-23, YAK-24 (Yakamoz)

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

- [ ] The production pipeline always runs with a bounded, configurable stream timeout.
- [ ] An empty-but-finished completion is observably distinct from an in-progress stream and
      from a timeout.
- [ ] A never-terminating stream surfaces `streamTimedOut` in core, for every consumer.
- [ ] `make verify` green; Monad/Shuttle build; Yakamoz `make verify` green.

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

---

## PKINT-005: Replace the run() Positional Parameter List With a Request Value to Eliminate Silent-Drop Footguns

**Priority:** P2
**Type:** API ergonomics / regression-prevention
**Depends on:** None
**Blocks:** Safe evolution of the run surface
**Surfaced by:** YAK-1, YAK-12 (Yakamoz)

### Summary

Collapse `PositronicKit.run(...)`'s ten defaulted positional parameters into a single
`ChatRunRequest` value type so that adding, removing, or omitting a field is explicit and
greppable, and a dropped argument cannot silently change behavior. YAK-12 deleted the
ambiguous overload; this removes the underlying shape that made the footgun possible.

### Current Problem

YAK-1/YAK-12: `structuredOutput:` was silently dropped from a call site, still compiled
(resolved to a different overload), and typed replies quietly stopped sending their schema.
The overload was collapsed (`Sources/PositronicKit/PositronicKit.swift:246` is now the single
`run`), but the function still has **ten** parameters, nine of them defaulted:

```swift
public func run(
    timelineId: UUID,
    message: String,
    tools: [AnyTool] = [],
    toolOutputs: [ToolOutputSubmission]? = nil,
    systemInstructions: String? = nil,
    agentInstanceId: UUID? = nil,
    maxTurns: Int = 5,
    generationParameters: GenerationParameters? = nil,
    structuredOutput: StructuredOutputRequest? = nil,
    promptAssemblyLogger: Logger? = nil
) async throws -> AsyncThrowingStream<ChatEvent, Error>
```

A long defaulted-parameter list is exactly the surface where the next field is silently
omittable. A request struct makes every field a named, type-checked member and makes "what did
this call site pass?" a single value to inspect/log.

### Files

- Add: `Sources/PositronicKit/...` `ChatRunRequest` value type (Sendable).
- Modify: `Sources/PositronicKit/PositronicKit.swift` (`run`) — replace the parameter list
  outright with `run(_ request: ChatRunRequest)`.
- Modify: `Sources/PositronicKitExamples/...` to use the request value.
- Modify: `Monad`/`Shuttle`/Yakamoz call sites (`YakamozRuntime.run` → `kit.run`).
- Modify: the `ChatRunning` protocol and its conformers (`YakamozRuntime`, `FollowUpRunner`)
  to match the new signature.

### Implementation Requirements

1. Introduce `ChatRunRequest` (Sendable) with `timelineId`/`message` required and the rest as
   members with the current defaults. Provide a memberwise init.
2. Make `run(_ request: ChatRunRequest)` the **only** API — delete the parameter-list `run`.
   Migrate every in-workspace call site (`PositronicKitExamples`, `Monad`, `Shuttle`,
   `YakamozRuntime`/`FollowUpRunner`) and the `ChatRunning` protocol in the same change. No
   deprecated shim.
3. `ChatRunRequest` should be cheaply loggable (`CustomStringConvertible` or a redacted
   summary) so a call site's exact configuration can be captured — directly useful for the
   kind of diagnosis YAK-23 needed.
4. No behavioral change for any field; this is a shape change only.

### Required Tests

- A test constructs a `ChatRunRequest`, runs through a mock, and asserts each field is honored
  (especially `structuredOutput`, the YAK-1 regression — assert the schema reaches the
  transport, mirroring the existing `StructuredOutputRunTests` guard).
- A test asserts a `ChatRunRequest` built with only the required fields applies the same
  defaults the old parameter list did (guards the migration against a changed default).

### Acceptance Criteria

- [ ] `run` takes a single `ChatRunRequest`; no defaulted-parameter pile remains as the
      primary surface.
- [ ] The structured-output regression guard passes against the new shape.
- [ ] `PositronicKitExamples` and all `Monad`/`Shuttle`/Yakamoz call sites use the request value.
- [ ] `make verify` green; downstream builds green.

### Handoff Notes

The goal is that a future field cannot be "dropped" — it is either set on the request or it is
the explicit default, and a code review sees the whole request at one call site. Keep
`ChatRunRequest` free of provider-specific types so it stays transport-neutral.

---

## PKINT-006: Give the TurnInspecting Seam a Stable Per-Send Turn Identity

**Priority:** P3
**Type:** API model clarity (leaky abstraction)
**Depends on:** None
**Blocks:** Clean inspector consumers (Yakamoz today, Monad later)
**Surfaced by:** YAK-2 (Yakamoz)

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

- [ ] `TurnInspecting` exposes a stable per-send identity distinguishing send from round-trip.
- [ ] A consumer can locate the response-bearing turn without a "latest row" workaround.
- [ ] Existing `turnIndex` semantics remain available and documented.
- [ ] `make verify` green; Yakamoz inspector tests updated and green.

### Handoff Notes

Coordinate the API shape with the Yakamoz `SwiftDataTurnInspector`/`ChatViewModel` consumer in
the same change — this seam exists primarily to serve inspector UIs, so the consumer's needs
define whether "terminal round-trip flag" or "round-trip count" is the better primitive.

---

## PKINT-007: Make Instance-Owned Cross-Send State Robust to Per-Send Reconfiguration

**Priority:** P3
**Type:** Composition robustness (latent state-loss footgun)
**Depends on:** None
**Blocks:** Consumers that rebuild the kit per send to pick up settings
**Surfaced by:** Yakamoz integration review (`YakamozRuntime.promptHistoryRegistry` hoist)

### Summary

Make cross-send runtime state (prompt-history/journal registry, inspection counters) safe by
construction when a consumer reconstructs `PositronicKit` per send to refresh provider
settings — either by supporting per-run reconfiguration without a full rebuild, or by clearly
owning/relocating the at-risk state so a fresh instance cannot silently reset it.

### Current Problem

Yakamoz must resolve fresh provider settings/API key on every send, so `YakamozRuntime.run`
builds a brand-new `PositronicKit` per send. A fresh instance gets a fresh
`TimelinePromptHistoryRegistry` and a reset inspection-turn counter — which would collide
turn-index 0 of each send with the previous send's row and silently overwrite persisted
inspection data. Yakamoz worked around this by hoisting one `TimelinePromptHistoryRegistry`
to runtime lifetime and threading it into every `makeKit` call (see the long comment in
`Yakamoz/Sources/YakamozCore/Runtime/YakamozRuntime.swift`). This is a sharp edge any consumer
that rebuilds per send will hit, and the only signal is silently corrupted inspection history.

### Files

- Modify: `Sources/PositronicKit/PositronicKit.swift` (construction / reconfiguration surface).
- Modify: the prompt-history registry / inspection-counter ownership in `Services/Chat/`.
- Add/Modify: tests covering reconfiguration without state loss.

### Implementation Requirements

1. Provide a supported way to update per-run provider configuration (model, api key, endpoint)
   on an existing `PositronicKit` instance — e.g. accept configuration per `run` (via the
   `ChatRunRequest` from PKINT-005) or a `reconfigure(configuration:)` method — so consumers do
   not need to reconstruct the instance to change settings.
2. If per-instance reconstruction remains a supported pattern, document explicitly which
   collaborators are *instance-lifetime stateful* (registry, inspection counter) and must be
   injected/shared by the caller, and make those parameters non-defaulted or otherwise
   hard to omit so the footgun is visible at the call site rather than discovered via
   corrupted data.
3. Preserve current behavior for consumers that already share a registry.

### Required Tests

- Two sequential sends that change provider configuration between them assert prompt-history /
  inspection state is continuous (no reset, no row overwrite) using the supported
  reconfiguration path.
- A test documenting the ownership: constructing a second instance without sharing the
  stateful collaborator is either prevented by the API or produces a clear, asserted outcome
  (not silent corruption).

### Acceptance Criteria

- [ ] A consumer can change provider settings between sends without losing prompt-history /
      inspection continuity and without a manual registry-hoist workaround.
- [ ] Instance-lifetime stateful collaborators are documented and hard to drop accidentally.
- [ ] `make verify` green; Monad/Shuttle build; Yakamoz can drop or simplify its hoist comment.

### Handoff Notes

This is the cleanest to land *after* PKINT-005, since a `ChatRunRequest` is the natural place
to carry per-send provider configuration and removes the original reason Yakamoz rebuilds the
kit at all.

---

## Completion Order and Gate

1. **PKINT-001** and **PKINT-002** first — both are P1 silent-failure correctness blockers and
   independent of each other.
2. **PKINT-003**, **PKINT-004**, **PKINT-005** next (P2); PKINT-005 should land before PKINT-007.
3. **PKINT-006** and **PKINT-007** last (P3 model-clarity); PKINT-007 depends on PKINT-005's
   `ChatRunRequest`.
4. Every ticket that changes a public API updates `PositronicKitExamples`, tests, and the
   `Monad`/`Shuttle`/Yakamoz call sites in the same change, and keeps `make verify` green in
   PositronicKit plus `swift build` clean in Monad and Shuttle.

The gate for this set: each fixed `YAK-*` defect is now defended by a contract + test in the
shared runtime, so the **class** of defect (not just the one instance) cannot recur in the
next provider or consumer without failing CI.
