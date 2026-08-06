# SDC-4 — Consolidate lenient/fallback JSON extraction on PartialJSON

**Status:** Done (landed in `PositronicKit/main` on 2026-07-04)
**Severity:** 🟢 Low (cleanup/robustness; no known active bug)
**Repos:** PositronicKit
**Source:** 2026-07-03 pre-sidecar simplification survey

## Problem

Once the sidecar work adds [PartialJSON](https://github.com/itruf/PartialJSON) as a PK
dependency (incremental/repairing JSON parsing), PK will contain three independent
hand-rolled "get JSON out of imperfect model output" mechanisms:

- `ToolOutputParser` (`Sources/PositronicKit/Utilities/ToolOutputParser.swift`) — regex +
  markdown-code-block scraping for fallback tool calls; the code-block path (`:123-151`) does
  strict `JSONDecoder` decoding, so a truncated or trailing-comma payload that PartialJSON
  could repair is dropped silently (returns `[]`).
- `StructuredOutputDecoder` (`Sources/PKShared/SharedTypes/StructuredOutputDecoder.swift`) —
  decodes complete structured responses; strict-only.
- The new `SidecarExtractionStage` — PartialJSON-based incremental parsing plus a
  first-non-whitespace-character passthrough decision (per the 2026-07-03 plan review: output
  not starting with `{` → whole buffer treated as `response`; see
  `workflow/PositronicKit/plans/2026-07-03-sidecar-directives-mechanism.md`, Task 5).

Three definitions of "leniently interpret model JSON" with different failure behavior.

## Suggested direction

After the sidecar mechanism lands:

1. Add one shared lenient-parse helper (PKShared or alongside the extraction stage) wrapping
   PartialJSON: `parseLenient(_ text: String) -> JSONValue?` with an optional
   code-fence/prefix-stripping preprocessing step.
2. Route `ToolOutputParser`'s code-block path and `StructuredOutputDecoder`'s failure path
   through it (strict decode first, lenient repair as fallback — repair must be logged, never
   silent, per the PKR-12 "no silent substitution" principle).
3. Reuse the same helper for the extraction stage's end-of-stream best-effort recovery so the
   sidecar error entries carry PartialJSON's best-effort value, as specified in the design spec.

Keep the pipe-delimited and XML tool-call scraping as-is (model-format-specific, not JSON
leniency). Tests: truncated / trailing-garbage / code-fenced payloads recovered identically
through all three call sites.

## Completion note

Landed via a shared `LenientJSONParser` in `PKShared`, now used by
`StructuredOutputDecoder`, `ToolOutputParser`, and `SidecarStreamExtractor` end-of-stream
recovery, with repair logging and focused regression tests.
