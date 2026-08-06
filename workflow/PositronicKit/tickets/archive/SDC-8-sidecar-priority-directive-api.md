# SDC-8 — Sidecar: public API for priority (before-`response`) directives

**Status:** Done (landed in `PositronicKit/main` before 2026-07-04; verified against current source)
**Repos:** PositronicKit
**Depends on:** SDC-7 (`priority_sidecar_payload` / `response` / `sidecar_payload` fixed
root-key convention must land first — this ticket is the consumer-facing API built on top of
it)
**Source:** `SidecarDirective` / `SidecarSchemaComposer` / `SidecarStreamExtractor`
(`workflow/PositronicKit/plans/2026-07-03-sidecar-directives-mechanism.md`)

## Problem

SDC-7 fixes wire-order for the sidecar mechanism by pinning three root-level schema keys —
`priority_sidecar_payload`, `response`, `sidecar_payload` — whose alphabetical order matches
the desired generation order. Today `SidecarDirective` has no way to say which container it
belongs to: every directive is a flat root property, composed by `SidecarSchemaComposer` as a
sibling of `response` (see current `compose(directives:)` in
`PositronicKit/.worktrees/sdc-sidecar-mechanism/Sources/PositronicKit/Services/Chat/SidecarSchemaComposer.swift:16-45`
and the shipped version at
`PositronicKit/Sources/PositronicKit/Services/Chat/SidecarSchemaComposer.swift`).

This ticket is the follow-on: give directives a `timing`/priority so `SidecarSchemaComposer`
can route them into the correct container, and update the incremental extractor
(`SidecarStreamExtractor`) and the shared event/result types to understand the nested
container shape instead of flat root properties.

## Scope

1. **`SidecarDirective` API** — add a way to mark a directive as "must precede `response`".
   Proposed: a new field

   ```swift
   public enum Timing: Sendable, Equatable, Codable {
       /// Generated before `response` (routing/gating decisions, refusal checks, etc.)
       case beforeResponse
       /// Generated after `response` (the common case: confidence, memory, tags, ...)
       case afterResponse
   }

   public let timing: Timing // default `.afterResponse`, added after `streaming` to keep
                              // existing call sites source-compatible via a default param
   ```

   Update `hasValidName`/reserved-name validation: the reserved set grows from `{"response"}`
   to `{"response", "priority_sidecar_payload", "sidecar_payload"}` — a directive can no
   longer be named any of the three container keys, since those are now structural, not
   directive-addressable.

2. **`SidecarSchemaComposer.compose(directives:)`** — partition directives by `timing` and
   emit the three-container schema:

   ```json
   {
     "type": "object",
     "properties": {
       "priority_sidecar_payload": { "type": "object", "properties": { ...beforeResponse... }, "required": [...], "additionalProperties": false },
       "response": { "type": "string", ... },
       "sidecar_payload": { "type": "object", "properties": { ...afterResponse... }, "required": [...], "additionalProperties": false }
     },
     "required": ["response"] + (priority container present ? ["priority_sidecar_payload"] : []) + (sidecar container present ? ["sidecar_payload"] : []),
     "additionalProperties": false
   }
   ```

   Omit `priority_sidecar_payload`/`sidecar_payload` entirely from `properties`/`required` when
   no directive uses that timing (a turn with only `afterResponse` directives should not gain
   an empty `priority_sidecar_payload: {}` requirement — extra required empty objects are
   needless strict-mode surface).

3. **`SidecarSchemaComposer.instructionBlock(directives:)`** — update prompt text to describe
   the container shape, not a flat field list: group directives by timing in the generated
   instructions ("Before your reply, produce these fields in `priority_sidecar_payload`: ...",
   "Put your reply in `response`.", "After your reply, produce these fields in
   `sidecar_payload`: ...").

   Note: `instructionBlock` now renders into the final `.userQuery` prompt section (not
   system instructions) — see the cache-stability change that moved per-turn directive text
   off the system prefix. This ticket only changes the block's *content* (container-grouped
   wording); it must not move the injection point. `SidecarSchemaComposer.mechanismPreamble`
   (the optional system-prompt preamble) is deliberately name-free/container-free and stays
   that way — do not add container-key language to it here.

4. **`SidecarStreamExtractor`** — the incremental parser currently walks flat top-level
   `directives` in declaration order (`reparse()`,
   `PositronicKit/.worktrees/sdc-sidecar-mechanism/.../SidecarStreamExtractor.swift:765-805`)
   and looks up `object[directive.name]` directly on the parsed root. This must change to look
   up `object["priority_sidecar_payload"]?[directive.name]` or
   `object["sidecar_payload"]?[directive.name]` depending on the directive's `timing`, and
   `laterKeyStarted`/field-completion heuristics need to operate *within* each container's
   raw-buffer key rather than across the flat root (a priority-container field completing must
   not be gated on `sidecar_payload` keys appearing, and vice versa — they're siblings in
   parallel containers, not one ordered list).
   - `response`'s suffix-streaming logic is unaffected (`object["response"]` unchanged).
   - `objectClosed()` (top-level brace balance) still gates the *last* directive within
     whichever container closes last in the object — verify this still correctly finalizes the
     last field of `sidecar_payload` (the container that closes last, since it's the last
     top-level key) versus `priority_sidecar_payload` (finalized once `response` or a
     `sidecar_payload` key starts appearing, i.e. `laterKeyStarted` must consider the *next
     top-level key* `"response"` as the boundary for the priority container's last field, not
     just sibling directive names).

5. **`SidecarError`** — extend `reservedOrInvalidName` coverage (or add a new case,
   `reservedContainerName`) for directives attempting to use one of the three container names.

## Non-goals

- Nested/recursive `propertyOrder` beyond the fixed three containers (SDC-7 scope note:
  sidecars only need top-level container order, not arbitrary nesting).
- Changing `SidecarDirective.reservedFieldName`'s existing meaning for `"response"` — it stays,
  the reserved set just grows.
- Yakamoz-side directive catalog / UI (separate plan, written after this lands on remote
  `main` per the sidecar mechanism plan's Task 9 handoff note).

## Smoke tests (priority ordering + container correctness)

Add to `SidecarSchemaComposerTests` and `SidecarStreamExtractorTests`:

- **`test_composeWithNoPriorityDirectives_omitsPriorityContainer`** — all directives
  `.afterResponse`; assert `priority_sidecar_payload` is absent from both `properties` and
  `required` in the encoded schema.
- **`test_composeWithNoAfterResponseDirectives_omitsSidecarPayloadContainer`** — mirror, for
  an all-`.beforeResponse` set.
- **`test_composeWithBothTimings_allThreeRootKeysPresentInOrder`** — mix of both; encode via
  the real `JSONEncoder().encode(schema.schema)` path and assert raw-string index order
  `priority_sidecar_payload` < `response` < `sidecar_payload` (mirrors SDC-7's
  `test_rootKeyOrder_*` tests but exercised through the composer's actual directive-partitioning
  logic, not a hand-built fixture).
- **`test_directiveNamedAfterReservedContainer_throws`** — a directive named
  `"priority_sidecar_payload"` or `"sidecar_payload"` throws `SidecarError` at `validate`/
  `compose` time (parallel to the existing `reservedNameThrows` test for `"response"`).
- **`test_extractor_priorityDirectiveDeliversBeforeResponseDelta`** — stream chunks where
  `priority_sidecar_payload` completes before any `response` text arrives; assert the
  `.sidecarDelta` for the priority directive is emitted (as an `Output`) before the first
  `.responseDelta` in the extractor's output ordering, mirroring the actual model-generation
  order this feature exists to enable.
- **`test_extractor_priorityAndAfterResponseDirectivesBothResolve`** — one directive per
  container in the same turn; assert both appear (with correct outcomes) in the final
  `.completed` results, and that container membership doesn't leak into `SidecarResult.name`
  (i.e. `name` stays the directive's own name, not container-qualified).
- **Per-provider wire smoke test** (parallel to SDC-7's) — run a directive set with both
  timings through `StructuredOutputExecution.prepare`/`prepareStreamRequest` for each provider
  and assert the composed request body still preserves the three-container root order after
  each provider's own encoding/envelope wrapping.

## Implementation notes

- This is additive to `SidecarDirective`'s public `Codable` shape (`timing` with a default) —
  should not require a data migration, but check for any persisted `SidecarDirective` JSON
  fixtures in `PKTestSupport`/Yakamoz test data that assume the old flat shape's field set.
- Land after SDC-7's root-key/container convention and its `ObjectSchema.encode(to:)` ordering
  investigation (Task 1 there) are confirmed — this ticket depends on that ordering being a
  real guarantee, not just observed `Dictionary` iteration.
- Downstream-sync checklist applies if `SidecarDirective`'s public initializer signature
  changes in a way that isn't purely additive-with-default (grep Yakamoz call sites, per
  `CLAUDE.md`'s downstream-sync checklist, once the Yakamoz adoption plan exists).

## Completion note

`SidecarDirective` now exposes `Timing` with `.beforeResponse`/`.afterResponse`, reserves the
container names, and the schema composer plus extractor route directives through the priority
and ordinary sidecar containers. Coverage lives in `SidecarDirectiveTests`,
`SidecarSchemaComposerTests`, and `SidecarStreamExtractorTests`.
