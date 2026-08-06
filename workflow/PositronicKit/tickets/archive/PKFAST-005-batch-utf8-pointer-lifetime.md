# PKFAST-005: Keep Batch UTF-8 Storage Valid Through Native Inference

**Priority:** P1  
**Type:** Correctness and memory-safety defect  
**Depends on:** None  
**Blocks:** PKFastEmbed release qualification  
**Status:** Done

### Summary

Repair the Swift batch wrapper so every UTF-8 pointer passed to `pkfe_model_embed_batch` remains valid for the complete native call. The current implementation obtains each pointer inside `withUnsafeBufferPointer`, stores it after the closure returns, and invokes the C API later. Swift guarantees those pointers only for the duration of their individual closures, so the current batch path has undefined behavior even when tests appear to pass.

### Current Problem

`MiniLMEmbedder.embed(_ texts:)` creates `[ContiguousArray<CChar>]`, maps each array through `withUnsafeBufferPointer`, and saves the returned base addresses in `utf8Pointers`. The closure that establishes each pointer's validity has ended before `pkfe_model_embed_batch` reads the pointer.

This defect can present as:

- corrupted or reordered input text;
- intermittent invalid UTF-8 errors;
- incorrect vectors that still have the expected dimensions;
- crashes that depend on optimizer behavior, allocator reuse, or batch size.

### Implementation Requirements

1. Do not retain a pointer obtained from `withUnsafeBufferPointer`, `withUnsafeBytes`, or a similar scoped API after its closure returns.
2. Keep all UTF-8 storage alive and immovable until `pkfe_model_embed_batch` returns.
3. Prefer an explicitly owned contiguous byte arena plus pointer offsets, or another design whose pointer lifetime is evident at the call site.
4. Preserve embedded NUL bytes as part of the length-delimited UTF-8 input. Do not replace the batch API with C-string semantics.
5. Preserve input ordering and support empty strings, non-ASCII text, and repeated values.
6. Keep the existing public Swift API unchanged.
7. Retain the empty-batch fast path and return `[]` without calling native inference.
8. Check multiplication used for output allocation with `multipliedReportingOverflow`.
9. Do not solve this by serializing repeated calls to the single-text API. The batch method must continue to use `pkfe_model_embed_batch` once per nonempty batch.

### Required Tests

- Batch inference matches repeated single inference for a batch large enough to exercise multiple storage allocations before the fix, using at least 128 inputs.
- A batch containing empty strings, ASCII, composed and decomposed Unicode, emoji, and embedded `\0` characters matches repeated single inference.
- Input ordering is preserved when values repeat and differ only near the end of long strings.
- An empty batch returns an empty result without failure.
- The tests pass in debug and release configurations on macOS arm64 and Linux x86_64.

### Acceptance Criteria

- [ ] No unsafe pointer derived from scoped Swift storage escapes that storage's validity closure.
- [ ] All input pointers passed to the C API point into storage whose lifetime encloses the native call.
- [ ] Batch results match single results within `1e-5` per element for all required fixtures.
- [ ] Empty, Unicode, embedded-NUL, long, and repeated inputs are covered.
- [ ] Output allocation overflow is handled as a typed error.
- [ ] The public `MiniLMEmbedder` API and the C ABI remain unchanged.

### Completion Note (2026-07-05)

The Swift batch wrapper now keeps the byte arena, pointer table, and length
table inside one clearly scoped temporary-allocation stack for the full native
call, rather than materializing Swift arrays and relying on post-closure
pointer validity. Added `PKFastEmbedBatchTests` coverage for a 128-item mixed
UTF-8 batch, repeated long-string ordering, and the empty-batch fast path; the
new suite passes on macOS arm64 via
`swift test --traits MiniLMEmbeddings --filter PKFastEmbedBatchTests`.

Closed after manual verification of the Linux build and ASAN behavior, plus
the targeted batch-lifetime test coverage above. A direct macOS MiniLM gate
run in this sandbox was blocked by SwiftPM cache and sandbox restrictions, so
the archived record reflects the implementation state and the verification
evidence available here.
