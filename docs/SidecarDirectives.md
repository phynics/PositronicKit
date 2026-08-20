# Sidecar Directives (Piggy-Backed Requests)

Sidecar directives let a chat turn produce auxiliary generations — a title, a summary, a tone
marker, a confidence score, whatever your app needs — **from the same LLM request** as the
turn's user-visible response, instead of paying a separate round-trip per auxiliary task. The
user sees only the streamed response; directive results arrive alongside it through
`ChatEvent`.

Full design rationale: `workflow/Yakamoz/specs/2026-07-03-piggybacked-requests-design.md`.
Architecture summary: [Architecture.md](Architecture.md#5-sidecar-directives-piggy-backed-requests).

## Why

Without sidecars, generating a conversation title or summary alongside a reply means either a
second LLM call after the turn completes (extra latency, extra cost) or hand-rolled prompt
hacks. Sidecars solve this by asking the model for one structured JSON object per turn: a
`response` field (streamed to the user like normal text) plus one field per directive, all
produced from the same context in a single request.

## Declaring a directive

```swift
import JSONSchemaBuilder
import PKContracts

let title = SidecarDirective(
    name: "title",
    instruction: "A short conversation title (3-6 words). Return null if the conversation already has a good title.",
    schema: JSONString().definition(),
    streaming: .buffered
)

let tone = SidecarDirective(
    name: "tone",
    instruction: "One word describing the emotional tone of this turn (e.g. \"neutral\", \"frustrated\", \"excited\").",
    schema: JSONString().definition(),
    streaming: .buffered
)
```

- `name` is the JSON field key. It must be unique per turn and cannot be `"response"` (reserved).
- `instruction` is prompt text describing what the model should produce for this field —
  injected into the turn's system instructions automatically.
- `schema` is a `JSONSchema.Schema` fragment for the field. Make it nullable (as above) to let
  the model explicitly decline.
- `streaming` controls delivery: `.buffered` delivers the value once, when complete;
  `.incremental` streams growing partial values as they generate (useful for long fields like
  summaries).

`PositronicKitUsageExamples.makeSidecarDirectives()` has a compiling reference pair
(`title` + `tone`) — see `swift run PositronicKitExamples`.

## Running a turn with sidecars

```swift
let stream = try await chat.run(ChatRunRequest(
    threadID: threadID,
    message: "What's the deal with actors in Swift 6?",
    sidecars: [title, tone]
))

for try await event in stream {
    if let text = event.textContent {
        // Stream to the UI exactly like a normal turn — no raw JSON ever appears here.
        print(text, terminator: "")
    }
    if let delta = event.sidecarDelta {
        // Route by delta.name ("title", "tone", ...); delta.isFinal marks the last update
        // for that field.
        print("\n[\(delta.name)] \(delta.partialText)")
    }
    if let completion = event.sidecarCompletion {
        // Durable side effects are keyed by identity, not event order.
        for result in completion.results {
            switch result.outcome {
            case let .value(value):
                print("\(result.name) = \(value)")
            case .declined:
                print("\(result.name) declined (model returned null)")
            case let .failed(reason):
                print("\(result.name) failed: \(reason)")
            }
        }
    }
}
```

`sidecars` defaults to `[]` — omitting it is behaviorally identical to today's plain-text
turns; no extractor is constructed and no extra schema is composed.

## Commit policy

Sidecars default to `SidecarCommitPolicy.everyRoundTrip`, which commits one identified
`SidecarCompletion` per successfully parsed LLM round-trip. For curation that must represent
the complete logical send, use `sidecarCommitPolicy: .terminalRoundTrip`. Intermediate
`.delta(.sidecar)` values are streaming observations, not durable commits. Under the terminal
policy, results are emitted only after tool and plugin follow-up work finishes normally;
cancellation, failure, max-turn exhaustion, and external-tool deferral do not promote an
intermediate result. Persist a completion idempotently using its `TurnIdentity`.

## Error model

A sidecar failure **never** fails the turn:

- **Explicit decline** (`"title": null`): reported as `.declined`, not an error.
- **Field never completes** (truncated stream, provider cutoff): reported as
  `.failed(reason:)`. Already-streamed response text is kept regardless.
- **Model ignores the schema entirely** (plain prose instead of JSON): the whole output falls
  back to `response`, and every directive reports `.failed`.
- **Invalid directives** (duplicate names, reserved `"response"` name): thrown as a structured
  `SidecarError` *before* any request is sent, so you catch configuration mistakes immediately
  rather than mid-stream.
- **Mutually exclusive with `structuredOutput`**: passing both `structuredOutput` and
  `sidecars` throws `SidecarError.conflictsWithExplicitStructuredOutput` — a turn can request
  one structured-output shape, not two competing ones.

## What sidecars don't do

This layer only provides the mechanism — schema composition, prompt injection, incremental
extraction, and event emission. It intentionally ships **no built-in directives**: title,
summary, and scheduling policy (e.g. "only generate a title once, then stop") are app-level
concerns that live in the consuming application (see Yakamoz's `SID-1`/`SID-2` tickets for a
worked example: a title directive with until-first-then-interval cadence).

One implementation detail worth knowing if you're deciding directive names: composed schema
field order does not control which field the model fills first — `Schema` stores properties
in an unordered `Dictionary`, so ordering is steered only through the instruction text, not
schema structure (tracked in ticket `SDC-7`).
