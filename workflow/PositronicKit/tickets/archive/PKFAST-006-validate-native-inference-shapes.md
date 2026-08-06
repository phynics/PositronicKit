# PKFAST-006: Validate Native Inference Shapes Before Copying Across the C ABI

**Priority:** P1  
**Type:** Native correctness and memory-safety defect  
**Depends on:** None  
**Blocks:** PKFastEmbed release qualification  
**Status:** Done

### Summary

Validate every FastEmbed inference result before copying it into caller-owned memory. The current Rust bridge hard-codes 384 dimensions, removes the first single result without checking that it exists, flattens batch results without checking their count or individual dimensions, and then copies the expected number of floats. Unexpected native output can therefore panic or read beyond the source allocation.

### Current Problem

The single path assumes `guard.embed(vec![text], None)` returns exactly one vector containing at least `model.dimensions` values. `embeddings.remove(0)` panics when no result exists, and `ptr::copy_nonoverlapping(..., model.dimensions)` reads out of bounds when the vector is short.

The batch path assumes FastEmbed returns exactly `text_count` vectors and that every vector contains exactly 384 values. It flattens whatever was returned, then copies `model.dimensions * text_count` values even if the flattened source is shorter.

Although the higher-level PositronicKit service checks pinned model assets, `PKFastEmbed` is a public companion package and must safely reject malformed, incompatible, or unexpectedly shaped model output on its own.

### Implementation Requirements

1. For single inference, require exactly one returned embedding.
2. For batch inference, require exactly `text_count` returned embeddings.
3. Require every returned embedding to contain exactly `model.dimensions` floats. Do not silently truncate or zero-pad incompatible output.
4. Perform all validation before any output bytes are copied. On failure, leave the caller's output buffer unchanged.
5. Return `Status::InferenceFailed` with a stable diagnostic that includes expected and actual counts or dimensions.
6. Replace unchecked `model.dimensions * text_count` with `checked_mul`. Return `Status::InvalidArgument` when the requested output size overflows `usize`.
7. Ensure no Rust panic can cross an exported C function boundary.
8. Convert a caught panic into a stable failure status and error message.
9. Do not change the successful output layout: batch vectors remain contiguous in input order, with 384 `Float32` values per input for the pinned model.
10. If the C ABI changes, increment `PKFASTEMBED_ABI_VERSION`.

### Required Tests

- Each malformed single result returns `PKFE_STATUS_INFERENCE_FAILED` without modifying the output buffer.
- Each malformed batch result returns `PKFE_STATUS_INFERENCE_FAILED` without modifying any part of the output buffer.
- Output-size overflow returns `PKFE_STATUS_INVALID_ARGUMENT` without allocation or inference.
- A controlled panic is contained and returned as a stable failure instead of unwinding across the C ABI.
- Valid single and batch inference continue to match the pinned golden vector and normalization requirements.
- Run the native suite with AddressSanitizer on at least Linux x86_64.

### Acceptance Criteria

- [ ] No vector is indexed, removed, flattened, or copied before its count and dimensions are validated.
- [ ] No source allocation can be read past its initialized length.
- [ ] Shape failure leaves the caller-provided output buffer unchanged.
- [ ] Integer overflow is rejected before allocation, slice construction, or pointer copying.
- [ ] Panics from bridge-owned or dependency code do not unwind through any exported C function.
- [ ] All failure paths return a stable status and an owned error string.
- [ ] Existing successful inference output remains byte-layout compatible unless an explicit ABI increment is required.

### Completion Note (2026-07-05)

The Rust bridge now validates embedding counts and per-vector dimensions before
copying any bytes into caller-owned buffers, preserves the unchanged-buffer
behavior on malformed output, and wraps every exported C entry point in a
panic-containment guard that returns a stable failure status plus owned error
message instead of unwinding across the ABI boundary. Native unit coverage now
includes the controlled-panic case; `cargo test` passes locally (`14` tests).

Closed after manual verification of the Linux build and ASAN behavior, plus
the native unit coverage above. A direct macOS MiniLM gate run in this sandbox
was blocked by SwiftPM cache and sandbox restrictions, so the archived record
reflects the implementation state and the verification evidence available here.
