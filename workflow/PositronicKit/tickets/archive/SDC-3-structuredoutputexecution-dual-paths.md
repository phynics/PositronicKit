# SDC-3 — `StructuredOutputExecution` has two divergent preparation paths

**Status:** Done (landed in `PositronicKit/main` before 2026-07-04; verified against current source)
**Severity:** 🟠 High (silent behavior divergence per provider), simplification payoff Medium
**Repos:** PositronicKit
**Source:** 2026-07-03 pre-sidecar simplification survey

## Problem

`Sources/PositronicKit/Services/LLM/LLMServiceProtocol+StructuredOutput.swift` prepares
structured-output requests through two parallel code paths that have drifted:

- `prepare`/`apply` (`:90-171`) — used by `chatStreamWithContext`
  (`LLMService+Stream.swift:22`). For `.openAICompatible` it returns
  `PreparedRequest(responseFormat: nil, promptAugmentation: nil)` — i.e. a `.jsonSchema`
  request is **silently dropped**: no response format, no prompt augmentation, no synthetic
  tool. The model receives nothing telling it to emit JSON.
- `prepareStreamRequest` (`:173-220`) — used by the `chatStream(structuredOutput:)` overload
  (and thus `ChatEngine`'s `LLMStreamingStage`). For `.openAICompatible` it correctly builds the
  synthetic-tool fallback (`emit_structured_response` + forced tool choice + stream rewrite).

Both switches also repeat the same `Schema` encode→decode roundtrip three times (`:135-140`,
`:152-157`, `:263-269`) and both construct the same `.jsonSchema` response format
independently. Per-provider silent substitution is the same failure family as PKR-12.

Failure scenario: a consumer on an `.openAICompatible` endpoint calls
`chatStreamWithContext` with `structuredOutput: .jsonSchema(...)` and gets free-form prose back;
decoding fails (or worse, half-parses) with no indication the request was never constrained.

## Suggested direction

Unify on a single preparation function returning the full `StreamRequest` shape (messages,
tools, toolChoice, responseFormat, syntheticToolName, promptAugmentation), and have both
`chatStreamWithContext` and `chatStream(structuredOutput:)` consume it. Specifically:

1. Fold `prepare`/`apply` into `prepareStreamRequest` (rename to `prepareRequest`); the
   non-stream path passes `tools: nil` and applies the augmentation/synthetic-tool result the
   same way.
2. Extract the `Schema` re-encode roundtrip into one helper (or eliminate it — investigate why
   the roundtrip exists at all; it appears to be a same-type deep copy).
3. `chatStreamWithContext` must also run `rewriteSyntheticToolStream` when a synthetic tool was
   used — today it cannot, which is part of why the fallback was omitted there. The sidecar
   feature's `SidecarExtractionStage` sits on top of this same machinery, so unification should
   land with (or before) the sidecar work.

Tests: per-provider matrix over the unified preparation (openAI/openRouter/ollama/
openAICompatible × jsonObject/jsonSchema), asserting response format, augmentation, and
synthetic-tool presence; regression test that `chatStreamWithContext` + `.openAICompatible` +
`.jsonSchema` yields a constrained request.

## Completion note

Current `StructuredOutputExecution.prepareRequest` is the unified preparation path used by both
`chatStreamWithContext` and `chatStream(structuredOutput:)`, and `.openAICompatible`
requests now use the synthetic tool fallback plus `rewriteSyntheticToolStream` on both paths.
Regression coverage lives in `StructuredOutputPreparationTests` and
`StructuredOutputPromptFlowTests`.
