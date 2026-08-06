# SDC-6 — Expand `PositronicKitExamples` with sidecar-directive patterns

**Status:** Done (landed in `PositronicKit/main` on 2026-07-04)
**Severity:** 🟢 Low (documentation-by-example; examples are PK's living docs)
**Repos:** PositronicKit
**Source:** 2026-07-03 follow-up discussion

## Problem

PK deliberately ships no built-in directives (title/section-title live in Yakamoz — SID-1/SID-2
in `workflow/Yakamoz/tickets/`). That makes `PositronicKitExamples` the place where the
intended directive patterns are demonstrated and kept compiling against the public API.

Current examples only touch structured output minimally:
`PositronicKitUsageExamples.makeStructuredOutputSchema()` builds one tag-extraction schema
(`Sources/PositronicKitExamples/PositronicKitUsageExamples.swift:94-104`) and `main.swift`
just prints it. Nothing demonstrates schema'd decoding, and (once the mechanism lands) nothing
would demonstrate sidecars.

## Suggested direction

Add worked examples (compiling, mock-service-driven where execution is needed):

1. **Basic sidecar turn:** define two `SidecarDirective`s (e.g. `title` with a nullable-string
   schema, `tone` with an enum schema), pass them to `executeTurn(sidecars:)`, and consume the
   event stream — showing that `.generation` deltas carry only the response text while
   `.sidecar`/`.sidecarsCompleted` carry the extras.
2. **Declinable directive pattern:** the nullable-field "model may return null" idiom
   (mirrors SID-1) including handling a declined result as a non-error.
3. **Cadence pattern:** a small pure schedule function (until-first-value, then every N turns)
   showing how a consumer decides per turn which directives ride — documenting the pattern
   Yakamoz implements, since PK keeps policy out of the runtime.
4. **One-shot directive reuse:** running a single directive standalone through
   `sendStructured` with a schema built from the same descriptor (ties to SDC-2's
   `run(directive:)` once it exists).
5. While in there, fix the existing structured-output example to actually decode
   (`sendStructured`/`StructuredOutputDecoder`) rather than only printing the schema.

Keep `swift run PositronicKitExamples` green; examples gate via `make verify`
(`verify-products`).

## Completion note

Landed with expanded `PositronicKitExamples` covering declinable directives, cadence helpers,
one-shot directive reuse, and actual structured-output decoding, plus matching example story
tests.
