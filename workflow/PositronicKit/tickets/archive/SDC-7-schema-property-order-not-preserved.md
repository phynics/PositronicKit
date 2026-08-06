# SDC-7 — `Schema` property order is not preserved through encoding (alphabetical on the wire)

**Status:** Done (landed in `PositronicKit/main` before 2026-07-04; verified against current source)
**Severity:** 🟠 Medium-High (silently defeats a documented design guarantee for *any* directive
name that sorts before the field it's meant to follow)
**Repos:** PositronicKit
**Source:** Implementation of `workflow/PositronicKit/plans/2026-07-03-sidecar-directives-mechanism.md`
Task 4 (`SidecarSchemaComposer`)

## Problem

The sidecar design (`workflow/Yakamoz/specs/2026-07-03-piggybacked-requests-design.md`) states
that declaring `response` first in the composed JSON schema "steers generation order" — i.e.
the model fills `response` before the piggy-backed directive fields, keeping the user-visible
text streaming ahead of the extras.

This does not hold. `swift-json-schema`'s `JSONValue` represents JSON objects as a plain Swift
`Dictionary` (`case object([String: Self])` — `JSONValue.swift:23`), which has no concept of
insertion order. Every `Schema` value — however it was constructed (`Schema(instance:)`,
`JSONSchemaBuilder`, or hand-rolled `ObjectSchema`) — loses declaration order the moment it's
parsed, and `ObjectSchema.encode(to:)` re-emits keys via `Dictionary` iteration.

Empirical check (encoding the same 3-property schema 5 times via `JSONEncoder().encode(schema)`):

```
{"required":[...],"properties":{"aaa":...,"response":...,"zzz":...},"type":"object"}
```

Properties consistently serialize in **alphabetical order**, not declaration order. This is not
new to sidecars — it's the existing behavior of every structured-output request in PK today
(`Sources/PositronicKit/Services/LLM/LLMServiceProtocol+StructuredOutput.swift:136,153,224,265`
all call `JSONEncoder().encode(schema.schema)` on the way to the wire).

**Failure scenario:** a sidecar directive named `error`, `answer`, `confidence`, or `memory`
(anything alphabetically before `"response"`) is composed as a "later" field, but the actual
JSON schema sent to the provider lists it *before* `response` — the opposite of the design's
"response streams first" guarantee, on directives the spec explicitly names as examples.

## Current mitigation (accepted 2026-07-03)

The sidecar mechanism (`SidecarSchemaComposer`) does **not** rely on structural property order.
It steers generation order only through the instruction block text ("put your reply in the
`response` field first..."), same as ordinary prompt-based guidance — not a structural
guarantee. This is a knowing weakening of the original design pending a real fix; tracked here
rather than silently accepted.

## Adopted direction — fixed root-key naming convention (Option D)

Rather than fixing property order generally (see "Rejected/deferred options" below), pin the
sidecar mechanism to exactly **three possible root-level keys**, chosen so that
`swift-json-schema`'s stable alphabetical encoding already produces the desired stream order.
No per-directive naming is required — individual directive fields nest *inside* these
containers, not at the schema root, so arbitrary directive names (`error`, `answer`,
`confidence`, `memory`, ...) never affect top-level ordering again:

| Root key                    | Alphabetical position | Purpose                                                        |
|------------------------------|------------------------|-----------------------------------------------------------------|
| `priority_sidecar_payload`   | 1st (before `response`) | Directives that must be decided/streamed *before* the user-visible reply (e.g. a routing or refusal decision that should gate `response` generation). |
| `response`                   | 2nd                     | The user-visible reply. Unchanged from today.                   |
| `sidecar_payload`            | 3rd (after `response`)  | Ordinary piggy-backed directives (confidence, memory, etc.) that should stream *after* the reply — the common case, matching the original design intent. |

Because `p` < `r` < `s`, `JSONEncoder`'s alphabetical re-emission places these three keys in
exactly this order on every provider, every time — this is a hard guarantee derived from
`String` comparison semantics, not an accident of the current library version's `Dictionary`
iteration (see empirical note above: iteration order was observed stable, but `Dictionary`
does not contractually promise it; alphabetical-by-`Comparable` sort, if that's what
`ObjectSchema.encode(to:)` actually does, *would* be a real contract — confirm which it is as
part of implementation, see Task 1 below).

`SidecarSchemaComposer` changes from emitting one flat object (`response` + N directive
properties) to emitting up to three objects: `priority_sidecar_payload` (object, optional
directives that must precede the reply), `response` (unchanged), `sidecar_payload` (object,
optional directives that follow the reply). Directives are declared as *members* of whichever
container matches their desired timing, never as root siblings of `response`.

### Implementation tasks

1. **Confirm the actual ordering mechanism.** Read `ObjectSchema.encode(to:)` in the
   `swift-json-schema` checkout (`.build/checkouts/swift-json-schema/Sources/JSONSchema/`) to
   determine whether key order is `Dictionary` iteration (version/hash-dependent, *not* a
   contract) or an explicit sort (a real contract). This changes the risk framing of the
   guarantee — document the finding in this ticket before relying on it further.

   **Finding (2026-07-04):** `swift-json-schema` stores `JSONValue.object` as
   `[String: JSONValue]` and its `Codable` implementation encodes that dictionary directly.
   Plain `JSONEncoder().encode(schema)` is therefore not an order contract; on the local
   Swift/Foundation build repeated encodes were observed to vary between `response` before
   `sidecar_payload` and the reverse. The implemented SDC-7 mitigation relies on the fixed
   alphabetical root-key convention **plus explicit `.sortedKeys` encoding at PositronicKit-owned
   provider request serialization boundaries** (OpenRouter request bodies, Ollama request
   bodies, and the OpenAI schema conversion path), with smoke tests covering those wire paths.
2. Update `SidecarSchemaComposer` (and the sidecar design doc,
   `workflow/Yakamoz/specs/2026-07-03-piggybacked-requests-design.md`) to compose the
   three-container shape instead of flat root properties.
3. Update/rename any existing sidecar directive call sites and fixtures that assumed flat
   root-level directive keys.
4. Add the smoke tests below and wire them into the normal `make verify` / `swift test` gate
   (not a separate manual check) so a future `swift-json-schema` bump or refactor of
   `ObjectSchema.encode(to:)` trips CI instead of silently regressing stream order.

### Smoke tests (ordering guarantee)

Add to the `PositronicKit` test target (co-located with existing
`LLMServiceProtocol+StructuredOutput` / sidecar tests):

- **`test_rootKeyOrder_allThreeContainersPresent`** — compose a schema with all three root
  keys present (`priority_sidecar_payload`, `response`, `sidecar_payload`), run it through the
  real `JSONEncoder().encode(schema.schema)` path used in
  `LLMServiceProtocol+StructuredOutput.swift`, decode the raw JSON text, and assert the
  substring order is `priority_sidecar_payload` index < `response` index < `sidecar_payload`
  index. Must inspect raw encoded bytes/string, not a re-parsed `Dictionary`/`Schema`, since
  the whole point is to catch order loss on the wire.
- **`test_rootKeyOrder_onlyResponseAndSidecarPayload`** — no priority directives present;
  assert `response` still precedes `sidecar_payload`.
- **`test_rootKeyOrder_onlyPriorityAndResponse`** — no trailing directives; assert
  `priority_sidecar_payload` precedes `response`.
- **`test_rootKeyOrder_stableAcrossRepeatedEncodes`** — encode the same composed schema N
  times (e.g. 20, mirroring the 5x empirical check in this ticket) and assert every encoding
  produces the identical key order — guards against non-contractual `Dictionary` iteration
  reintroducing nondeterminism after a Swift/Foundation/library version bump.
- **Per-provider wire smoke test** — for each of `.openAI`/`.openRouter`, `.ollama`, and the
  `.openAICompatible` synthetic-tool path, run the actual `StructuredOutputExecution.prepare`/
  `prepareStreamRequest` used in `LLMServiceProtocol+StructuredOutput.swift`, encode the
  resulting provider request body, and assert the same root-key ordering survives each
  provider's specific envelope (`response_format.json_schema.schema`, Ollama's `format`, the
  synthetic tool's `parameters`). This is the regression that actually matters — the top-level
  `Schema` test alone would not have caught the OpenAI MacPaw re-decode losing order if that
  path behaves differently.

## Rejected/deferred options (evaluated, not chosen)

For reference, other options considered and why they weren't picked for now:

1. **General order-preserving wire type** (ordered-dictionary-backed value type replacing
   `Schema` at the wire boundary, with an explicit `propertyOrder` on
   `StructuredOutputSchema`). Would fix ordering for *all* structured-output schemas, not just
   the three sidecar keys, and overlaps with **SDC-3** (`StructuredOutputExecution` dual
   preparation paths). Deferred: larger surface (touches `LLMResponseFormat`, all provider
   adapters, `PKShared` public API, downstream-sync checklist for Monad/Shuttle/Yakamoz), and
   the OpenAI path re-decodes into MacPaw's own dictionary-backed `JSONSchema` type
   (`OpenAIConversions.swift:160`), which would need separate handling regardless.
2. **Post-encode body rewrite at the transport seam.** Rejected as fragile string/JSON surgery
   living at the wrong altitude, with no clean interception point for the MacPaw-owned OpenAI
   request encoding.
3. **Upstream fix in `swift-json-schema`** (ordered-object `JSONValue.object` case). Correct
   root-cause fix but out of PK's control and long-lead; worth filing upstream in parallel but
   not blocking this ticket. Even if landed, the OpenAI MacPaw re-decode would still need
   separate handling.
4. **Accept prompt-based steering permanently.** Rejected: on OpenAI strict mode, constrained
   decoding follows schema property order mechanically, so the prompt instruction is actively
   contradicted on the flagship provider — leaves a documented design guarantee silently false
   exactly where structured output is strongest.

## Completion note

The fixed three-root-key convention (`priority_sidecar_payload`, `response`,
`sidecar_payload`) is now implemented in `SidecarSchemaComposer`, with corresponding ordering
and smoke coverage in `SidecarSchemaComposerTests` and `StructuredOutputPreparationTests`.
