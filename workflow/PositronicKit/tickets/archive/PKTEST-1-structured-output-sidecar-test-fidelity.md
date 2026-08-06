# PKTEST-1 — Structured-output / sidecar-directive test fidelity (false-green outcome shapes)

**Priority:** P2
**Type:** Test coverage / contract gap (cross-cuts PK + Yakamoz)
**Depends on:** none
**Blocks:** none
**Status:** Done
**Resolution:** Added `SidecarOutcomeContractTests` (10 tests) pinning the `SidecarResult.outcome .value`
`AnyCodable` case tag for both leaf-scalar (`.string`) and `@Schemable` object-schema (`.dictionary`)
directive shapes, plus `null`→`.declined`, missing/wrong key→`.failed`, and `Codable` round-trip
preserving the case tag. Documented the payload-value contract in a doc comment on
`SidecarResult.Outcome.value` (`SidecarEvents.swift`). Strict-mode investigation confirmed a real
OpenAI strict-mode conflict: `@Schemable` omits `required` for all-optional payloads while
`SidecarSchemaComposer.compose` sets `strict: true`. Follow-up filed as PKTEST-3. `make verify` green
(900 tests / 157 suites). Commits: `0687592`, merge `1240a5c`.

### Summary

PositronicKit's sidecar-directive mechanism (SDC series, done) and `SidecarStreamExtractor`
emit `SidecarResult.outcome == .value(AnyCodable(...))` carrying the **per-directive payload
object** (a `{title: String?}` sub-object for the `title` directive). Downstream consumers
and PositronicKit's own tests read the value as a **bare string** via `AnyCodable.asString`,
which returns `nil` for `.dictionary` (`AnyCodable.swift:38-41`). That contract mismatch is
silently invisible to the test suite because the tests feed `AnyCodable("a string")` (bare
string) instead of the runtime shape `AnyCodable.dictionary([...])`. Yakamoz shipped a
production bug (SID-3) that way; this ticket closes the underlying test-fidelity gap so
neither PK nor a future consumer can repeat it.

Two related gaps to close:

1. **Outcome-shape contract tests** — the extractor's emitted `.value` shape (payload dict
   keyed by directive name) is not asserted anywhere in PositronicKit. There is no test
   stating "for an after-response directive with a `{title: String?}` schema, the
   `SidecarResult` carries `.value(.dictionary(["title": .string("…")]))`". So consumers (and
   PositronicKit internals) are free to assume the wrong shape.
2. **Optional-not-in-required + `strict: true` under OpenAI strict mode** —
   `SidecarSchemaComposer.compose` (`SidecarSchemaComposer.swift:72-77`) sets `strict: true`
   on the composed schema while `TitleDirectivePayload.title` is an optional *not* listed in
   `required` (Yakamoz `TitleDirectiveTests.swift:25` asserts this as a feature). OpenAI's
   strict-JSON-schema mode rejects optionals missing from `required`; the symptom is the
   schema silently degrading on the provider and the model freelancing off-schema keys
   (observed in production: the model returned `{"text": "..."}` instead of
   `{"title": "..."}`). There is no PositronicKit test that exercises the container schema's
   `required` array against strict-mode constraints, nor one that catches the
   "model ignored schema" failure mode end-to-end.

### Current problem

- `PositronicKit/Tests/PositronicKitTests/...sidecar...` — search for `outcome: .value` in
  the sidecar extractor / composer tests. Cases that feed a model JSON response and assert
  `SidecarResult` either assert non-`nil` value presence only (not its shape) or feed a bare
  string. Concretely, the Discriminator-style extractor tests verified the directive
  payloads by parsing string partials, not by inspecting the `AnyCodable` case tag.
- `PositronicKit/Sources/PositronicKit/Services/Chat/SidecarStreamExtractor.swift:75-77` —
  the emitted value is `AnyCodable(payload[directive.name])` where
  `payload[directive.name]` is the per-directive payload sub-object. This contract is
  undocumented in tests.
- `PositronicKit/Sources/PositronicKit/Services/Chat/SidecarSchemaComposer.swift:131-143` —
  `containerSchema` builds `{type: object, properties: {...}, required: [all directive names],
  additionalProperties: false}` for the parent container, but each *inner* directive schema's
  `required` is whatever `@Schemable` produced — which omits optionals. With `strict: true`
  on the outer request, the inner optional-not-required combination is the suspect.
- No test asserts what happens when a provider legitimately cannot apply the composed strict
  schema (rejection, schema downgrade, or model freeform) — the extractor's `finish()`
  "field missing at stream end" / passthrough paths (`SidecarStreamExtractor.swift:46-50`,
  `:65-92`) cover the worst case but not the "model emitted structured JSON with wrong keys"
  case.

### Implementation requirements

1. **Add outcome-shape contract tests** in `Tests/PositronicKitTests/` (mirror the existing
   sidecar extractor test file). For an after-response directive whose schema is a single
   optional `_String?_` field named `title`, feed a complete model JSON like
   `{"response": "...", "sidecar_payload": {"title": "Hello"}}` and assert:
   - `SidecarResult(name: "title", outcome: .value(...))` where the value's `AnyCodable` case
     is `.dictionary(["title": .string("Hello")])` *exactly* — pin the case tag, not just
     `.asString`.
   - The same for `null`: `outcome == .declined` (not `.value(.null)`).
   - The same for a missing key at stream end: `outcome == .failed(reason:)`.
2. **Add a cross-check test** that takes a `SidecarResult` emitted by the extractor and
   round-trips it through `Codable` (the same path consumers use to persist it on
   `ResponseDTO`/SwiftData), then asserts the round-tripped `AnyCodable` still round-trips to
   `.dictionary`. This is the contract Yakamoz's coordinator depends on; it must not regress
   silently.
3. **Document the outcome contract** in a doc comment on `SidecarResult.Outcome.value`
   (`SidecarEvents.swift:21`). State: "the value is the per-directive payload object as parsed
   from `sidecar_payload.<directive.name>`, not a bare scalar — consumers must decode through
   the directive's payload type, not assume `AnyCodable.asString`." Cite this ticket in the
   comment.
4. **Strict-mode + optional-`required` investigation** (no code change committed by this
   ticket alone — surface the finding and either fix in PK or file a follow-up):
   - Add a test in `Tests/PositronicKitTests/` that builds the composed schema for a directive
     whose payload has an optional scalar field (`String?`) and asserts what the emitted
     JSON Schema's inner object's `required` array contains. If the optional is omitted
     (current `@Schemable` default), and the outer request is `strict: true`, document the
     conflict against OpenAI's strict-JSON-schema rules (optionals must be in `required` and
     marked `type: ["string", "null"]`).
   - If a real incompatibility is confirmed, either (a) lower `strict` to `false` for
     nullable-payload directives, (b) add the optional to `required` and adjust
     `TitleDirectivePayload` so `@Schemable` emits the nullable union (revisit
     `TitleDirectiveTests.swift:25` accordingly), or (c) file a follow-up PK ticket with the
     fix scoped. Whichever is chosen, **Yakamoz's recover/single-string tolerance (SID-3)
     must remain the safety net** — don't rely solely on provider strictness.
5. **Add a "model ignored schema" extractor test** feeding a model JSON where the sidecar
   payload key is *not* the directive's name (e.g. `{"text": "..."}` for a `title`
   directive) and assert: the directive is reported as `.failed(reason:)` with a stable
   reason string, not silently `.value(...)`. This documents the contract for consumers
   (Sid-3's recover path can be more lenient than the PK contract — PK should report; the
   consumer decides whether to heal).

### Acceptance criteria

- [ ] Sidecar extractor test pins `SidecarResult.outcome == .value`'s `AnyCodable` case tag
      as `.dictionary` for an after-response directive (not just "value is non-nil").
- [ ] Round-trip `Codable` test for `SidecarResult` with a dict-shaped value passes and
      guards against silent `.dictionary`→`.string` regressions.
- [ ] `SidecarResult.Outcome.value` carries a doc comment documenting the payload-object
      contract and citing this ticket.
- [ ] Investigation test for the strict-mode + optional-`required` interaction is added; if
      the conflict is confirmed, a fix or a follow-up ticket is filed with the scope
      captured.
- [ ] Extractor test covers the "model emitted structured JSON with wrong sidecar keys" path
      and pins the `.failed(reason:)` outcome.
- [ ] `make verify` green with the new tests executing (check the count, not just exit 0).
- [ ] CHANGELOG.md updated under `Unreleased` if any public-type doc comment change lands.