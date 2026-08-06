# SDC-2 — Express LLM utility generations as directive descriptors

**Status:** Done (landed in `PositronicKit/main` on 2026-07-04)
**Severity:** 🟡 Medium (three hand-rolled JSON-prompt paths; silent error swallowing; loose `.jsonObject` mode)
**Repos:** PositronicKit
**Source:** 2026-07-03 pre-sidecar simplification survey

## Problem

`Sources/PositronicKit/Services/LLM/LLMService+Utilities.swift` contains three auxiliary
generations that each hand-roll what `SidecarDirective` formalizes:

- `generateTags(for:)` (`:7-30`) — inline "Return ONLY a JSON object with a key \"tags\"…"
  prompt, loose `.jsonObject` (no schema despite having a `LLMTagResponse` model), catches all
  errors and silently returns `[]`.
- `generateTitle(for:)` (`:33-65`) — inline "Return ONLY the title text…" prompt, plain text,
  manual quote-stripping, silently returns `"New Conversation"` on error.
- `evaluateRecallPerformance(transcript:recalledMemories:)` (`:72-119`) — inline "Return ONLY a
  JSON object where keys are memory IDs…" prompt, loose `.jsonObject` decoded as
  `[String: Double]` (no schema), silently returns `[:]`.

Three copies of the same shape: instruction text + implied schema + decode + swallow-and-default.
The sidecar work introduces exactly this descriptor (`SidecarDirective`: name, instruction,
schema, streaming mode) plus the "auxiliary failure never fails the caller" error model.

## Suggested direction

1. Once `SidecarDirective` exists in PKShared, add a one-shot execution path, e.g.
   `LLMServiceProtocol.run(directive:input:)` → `sendStructured` with
   `.jsonSchema` built from the directive (reusing the sidecar schema-composition code for the
   single-field case), decoding via `StructuredOutputDecoder`.
2. Re-express `generateTags` / `generateTitle` / `evaluateRecallPerformance` as three canonical
   directive descriptors + thin typed wrappers over `run(directive:)`. Schemas derive via
   `@Schemable`/`JSONSchemaBuilder` (e.g. `LLMTagResponse`), replacing loose `.jsonObject`.
3. Make error policy explicit and shared (one helper that logs via
   `ErrorKit.userFriendlyMessage(for:)` and returns the directive's declared default) instead of
   three copy-pasted `do/catch` blocks.
4. These same descriptors become directly piggy-backable by consumers (e.g. Yakamoz's `title`
   directive), so prompt wording lives in one place. Pairs with SDC-1.

Tests: each wrapper asserts (a) schema'd request sent, (b) default returned + error logged on
failure, using `PKTestSupport` mocks.

## Completion note

Landed as the shared utility-generation descriptor path in `LLMService+Utilities`, with
schema-backed tags/title/recall-eval requests, shared logging/default handling, and expanded
tests in `LLMServiceTests`.
