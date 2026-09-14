# Sidecar directives

Sidecar directives add auxiliary structured results to the same Turn as the user-visible response.
The model produces one structured object, and PositronicKit streams response text normally while
exposing directive updates through `TurnEvent`.

The runtime owns the contract. Applications decide which directives to request and how to persist
their results. See [Turn admission and execution](Architecture.md#turn-admission-and-execution).

## Why

Without sidecars, generating a title or summary alongside a reply requires another model call or
an application-specific prompt format. Sidecars use one structured JSON object per Turn with a
`response` field plus one field per directive.

## Define a directive

```swift
import JSONSchemaBuilder
import PKContracts

let title = SidecarDirective(
    name: "title",
    instruction: "A short thread title (3-6 words). Return null if the thread already has a good title.",
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
- `instruction` is prompt text describing what the model should produce for this field. The runtime
  injects it into the Turn's system instructions.
- `schema` is a `JSONSchema.Schema` fragment for the field. Make it nullable (as above) to let
  the model explicitly decline.
- `streaming` controls delivery. `.buffered` delivers the value once when complete. `.incremental`
  streams growing partial values as they generate.

`PositronicKitUsageExamples.makeSidecarDirectives()` has a compiling reference pair
(`title` + `tone`). Run it with `swift run PositronicKitExamples`.

## Run a Turn with sidecars

```swift
let turn = try await chat.threads.open(threadID).startTurn(
    "What's the deal with actors in Swift 6?",
    options: TurnOptions(sidecars: [title, tone])
)

for await event in turn.events() {
    if let text = event.textContent {
        // Stream to the UI like a normal Turn. Raw JSON does not appear here.
        print(text, terminator: "")
    }
    if let delta = event.sidecarDelta {
        // Route by delta.name ("title", "tone", ...). delta.isFinal marks the last update
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

`sidecars` defaults to `[]`. Omitting it keeps the ordinary text path and does not construct an
auxiliary schema.

## Choose a commit policy

Sidecars default to `SidecarCommitPolicy.everyModelRound`, which commits one identified
`SidecarCompletion` per successfully parsed LLM round-trip. For curation that must represent
the complete logical send, use `sidecarCommitPolicy: .terminalModelRound`. Intermediate
`.delta(.sidecar)` values are streaming observations, not durable commits.

Under the terminal policy, results are emitted only after tool and plugin follow-up work finishes
normally. Cancellation, failure, model-round exhaustion, and external-tool deferral do not promote
an intermediate result. Persist a completion idempotently using its `TurnIdentity`.

## Handle failures

A sidecar failure **never** fails the turn:

- **Explicit decline** (`"title": null`): reported as `.declined`, not an error.
- **Field never completes** (truncated stream, provider cutoff): reported as
  `.failed(reason:)`. Already-streamed response text is kept regardless.
- **Model ignores the schema entirely** (plain prose instead of JSON): the whole output falls
  back to `response`, and every directive reports `.failed`.
- **Invalid directives** (duplicate names, reserved `"response"` name): thrown as a structured
  `SidecarError` *before* any request is sent, so you catch configuration mistakes immediately
  rather than mid-stream.
- **Mutually exclusive with `structuredOutput`**: passing both `structuredOutput` and `sidecars`
  throws `SidecarError.conflictsWithExplicitStructuredOutput`. A Turn can request one
  structured-output shape, not two competing ones.

## What sidecars don't do

This layer provides schema composition, prompt injection, incremental extraction, and event
emission. It ships no built-in directives. Title, summary, and scheduling policy belong to the
consuming application.

Composed schema field order does not control which field the model fills first. `Schema` stores
properties in an unordered `Dictionary`, so use instruction text when field order matters.
