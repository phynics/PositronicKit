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
import PKShared

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
let stream = try await chat.run(
    timelineId: timelineId,
    message: "What's the deal with actors in Swift 6?",
    sidecars: [title, tone]
)

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
    if let results = event.sidecarResults {
        // Terminal outcome per directive for the turn.
        for result in results {
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

## Priority & ordering

Two different notions of "order" apply here, and they're easy to conflate:

**1. The array order you pass to `sidecars:` sets extraction priority.** `SidecarStreamExtractor`
watches the raw JSON as it streams and finalizes a directive's value either when the object
closes, or as soon as a *later* directive's key (later in your declared array) appears in the
buffer. In other words, declaration order is the priority in which directives are expected to
resolve — put directives you want resolved earlier first:

```swift
// "title" is expected to finish before "summary" — its value finalizes as soon as
// the "summary" key starts appearing in the stream (or sooner, if the model completes
// title outright). The last directive in the list only finalizes when the object closes.
sidecars: [title, summary]
```

This is real, load-bearing behavior — reorder your directives and you reorder when their
`.sidecar` completion deltas fire relative to each other.

**2. Composed JSON schema field order does *not* control model generation order.** You might
expect declaring `response` first in the schema to make the model *write* `response` first
(and thus keep it streaming ahead of directive fields). It doesn't: `Schema`/`JSONValue` store
object properties in an unordered `Dictionary`, and the wire-serialization path
(`JSONEncoder().encode(schema.schema)`) re-emits keys alphabetically regardless of declaration
order. Generation order is steered only through `instructionBlock`'s prompt text ("put your
reply in the `response` field first"), not schema structure — a soft instruction, not a hard
guarantee. Tracked in ticket `SDC-7` as a known gap; the array-order priority in point 1 is
unaffected by this and remains reliable regardless of how #2 is eventually resolved.

## What sidecars don't do

This layer only provides the mechanism — schema composition, prompt injection, incremental
extraction, and event emission. It intentionally ships **no built-in directives**: title,
summary, and scheduling policy (e.g. "only generate a title once, then stop") are app-level
concerns that live in the consuming application (see Yakamoz's `SID-1`/`SID-2` tickets for a
worked example: a title directive with until-first-then-interval cadence).
