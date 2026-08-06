# PKTEST-2 — Synthetic-tool stream rewriter drops non-synthetic tool calls in mixed chunks

**Priority:** P2
**Type:** Test-coverage-discovered behavior gap (structured output / synthetic-tool fallback)
**Depends on:** none
**Blocks:** none
**Status:** Done
**Resolution:** `rewriteSyntheticToolChunk` now returns `[LLMStreamChunk]` instead of a single optional.
Mixed chunks yield the merged synthetic content first, then a separate chunk carrying the
non-synthetic tool-call deltas with `finishReason`/`usage` deferred to the trailing chunk (so
completion and token totals are reported exactly once). All-synthetic and all-non-synthetic chunks
are unchanged. Updated `mixedSyntheticAndNonSyntheticToolCallsInOneChunk` to assert the 2-chunk
contract; added `mixedChunkWithEmptySyntheticArgumentsPreservesNonSyntheticToolCalls`.
`make verify` green (900 tests / 157 suites). Commits: `b9e51d7`, merge `1240a5c`.

### Summary

When a provider uses the synthetic-tool fallback for JSON-schema structured output
(`openAICompatible` and `anthropic` paths), `StructuredOutputExecution.rewriteSyntheticToolStream`
rewrites each `LLMStreamChunk` that contains a tool call named `emit_structured_response` into a
content chunk carrying the tool-call arguments. If a single chunk contains **both** a synthetic
tool call and a real non-synthetic tool call, the current implementation emits **only** the
synthetic content and discards the non-synthetic tool call(s).

This was surfaced by the new `StructuredOutputSyntheticToolStreamTests` coverage added for
structured-generation parsing validation. The behavior is consistent today, but it is almost
certainly not intentional: a model that emits a real tool call and a structured-response tool
call in the same chunk should not silently lose the real tool call.

### Current problem

- `Sources/PositronicKit/Services/LLM/LLMServiceProtocol+StructuredOutput.swift:118-143` —
  `rewriteSyntheticToolChunk` returns a single `LLMStreamChunk?`. When synthetic calls are found
  it returns a new content chunk; it never returns the original chunk with non-synthetic calls
  preserved.
- The downstream consumer (`sendStructuredMessage`, `LLMStreamingStage`, etc.) then sees only
  the synthetic JSON content and never receives the real tool call delta.
- There is no documented contract stating whether mixed chunks are expected, and no existing
  test asserted the behavior before the new coverage.

### Reproduction

The new test
`StructuredOutputSyntheticToolStreamTests.mixedSyntheticAndNonSyntheticToolCallsInOneChunk`
documents the current output: given one chunk containing both `lookup_weather` and
`emit_structured_response`, the rewriter yields a single chunk whose content is the synthetic
JSON and no chunk containing `lookup_weather`.

### Implementation requirements

1. **Decide the intended contract.** Likely: a mixed chunk should yield **two** chunks — one
   content chunk for the merged synthetic tool-call arguments, and one pass-through chunk for
   the remaining non-synthetic tool calls (with finish reason and metadata preserved).
2. **Update `rewriteSyntheticToolChunk`** to return an array of `LLMStreamChunk`s (or yield
   multiple chunks from `rewriteSyntheticToolStream`) so both the synthetic content and the
   non-synthetic tool-call chunk can be emitted.
3. **Preserve ordering.** The synthetic content should probably be emitted first (it represents
   the assistant's structured response), followed by the non-synthetic tool-call chunk.
4. **Add/update tests** in `StructuredOutputSyntheticToolStreamTests.swift` to assert the new
   contract:
   - Mixed chunk → synthetic content chunk + non-synthetic tool-call chunk.
   - All-synthetic chunk → single content chunk (existing behavior unchanged).
   - All-non-synthetic chunk → pass-through unchanged (existing behavior unchanged).
5. **Run the structured-output focused suites and the full `make verify` gate.** Ensure no
   consumer of `rewriteSyntheticToolStream` breaks when the stream yields an extra chunk.

### Acceptance criteria

- [ ] `rewriteSyntheticToolChunk` / `rewriteSyntheticToolStream` preserves non-synthetic tool
      calls when they share a chunk with synthetic calls.
- [ ] `StructuredOutputSyntheticToolStreamTests` asserts the mixed-chunk contract explicitly
      (not as a documented limitation).
- [ ] Existing synthetic-tool-only and non-synthetic-only tests still pass unchanged.
- [ ] `swift test --filter StructuredOutputSyntheticToolStreamTests` and `make verify` green.
- [ ] CHANGELOG.md updated under `Unreleased` if the fix changes observable runtime behavior.
