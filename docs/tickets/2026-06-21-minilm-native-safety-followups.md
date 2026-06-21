# MiniLM Native Safety Follow-up Tickets

These tickets address the Swift and Rust boundary defects found while reviewing commit `86d6b4a` (`Repair local embeddings for Linux`). Complete **PKFAST-005** and **PKFAST-006** before treating the native MiniLM backend as production-safe. **PKFAST-007** is independent and may be implemented in parallel, but all three tickets should land before the companion package is released.

## PKFAST-005: Keep Batch UTF-8 Storage Valid Through Native Inference

**Priority:** P1  
**Type:** Correctness and memory-safety defect  
**Depends on:** None  
**Blocks:** PKFastEmbed release qualification

### Summary

Repair the Swift batch wrapper so every UTF-8 pointer passed to `pkfe_model_embed_batch` remains valid for the complete native call. The current implementation obtains each pointer inside `withUnsafeBufferPointer`, stores it after the closure returns, and invokes the C API later. Swift guarantees those pointers only for the duration of their individual closures, so the current batch path has undefined behavior even when tests appear to pass.

### Current Problem

`MiniLMEmbedder.embed(_ texts:)` creates `[ContiguousArray<CChar>]`, maps each array through `withUnsafeBufferPointer`, and saves the returned base addresses in `utf8Pointers`. The closure that establishes each pointer's validity has ended before `pkfe_model_embed_batch` reads the pointer.

This defect can present as:

- corrupted or reordered input text;
- intermittent invalid UTF-8 errors;
- incorrect vectors that still have the expected dimensions;
- crashes that depend on optimizer behavior, allocator reuse, or batch size.

The existing three-element batch test checks output semantics but does not prove pointer lifetime correctness.

### Files

- Modify: `Packages/PKFastEmbed/Sources/PKFastEmbed/PKFastEmbed.swift`
- Modify: `Packages/PKFastEmbed/Tests/PKFastEmbedTests/PKFastEmbedTests.swift`
- Modify only if a reusable scoped-buffer helper is introduced: a new source file under `Packages/PKFastEmbed/Sources/PKFastEmbed/`

### Implementation Requirements

1. Do not retain a pointer obtained from `withUnsafeBufferPointer`, `withUnsafeBytes`, or a similar scoped API after its closure returns.
2. Keep all UTF-8 storage alive and immovable until `pkfe_model_embed_batch` returns.
3. Prefer an explicitly owned contiguous byte arena plus pointer offsets, or another design whose pointer lifetime is evident at the call site.
4. Preserve embedded NUL bytes as part of the length-delimited UTF-8 input. Do not replace the batch API with C-string semantics.
5. Preserve input ordering and support empty strings, non-ASCII text, and repeated values.
6. Keep the existing public Swift API unchanged:

```swift
public func embed(_ texts: [String]) throws -> [[Float]]
```

7. Retain the empty-batch fast path and return `[]` without calling native inference.
8. Check multiplication used for output allocation with `multipliedReportingOverflow`; reject impossible batch sizes with `PKFastEmbedError.invalidArgument` rather than trapping.
9. Do not solve this by serializing repeated calls to the single-text API. The batch method must continue to use `pkfe_model_embed_batch` once per nonempty batch.

### Required Tests

- Batch inference matches repeated single inference for a batch large enough to exercise multiple storage allocations before the fix, using at least 128 inputs.
- A batch containing empty strings, ASCII, composed and decomposed Unicode, emoji, and embedded `\0` characters matches repeated single inference.
- Input ordering is preserved when values repeat and differ only near the end of long strings.
- An empty batch returns an empty result without failure.
- A focused test or internal test hook proves the batch implementation invokes the native batch entry point once rather than falling back to repeated single inference.
- The tests pass in debug and release configurations on macOS arm64 and Linux x86_64.
- Run the focused suite under AddressSanitizer on a supported CI runner if Swift/Rust static linking permits it; if it does not, record the toolchain limitation in the ticket outcome.

### Acceptance Criteria

- [ ] No unsafe pointer derived from scoped Swift storage escapes that storage's validity closure.
- [ ] All input pointers passed to the C API point into storage whose lifetime encloses the native call.
- [ ] Batch results match single results within `1e-5` per element for all required fixtures.
- [ ] Empty, Unicode, embedded-NUL, long, and repeated inputs are covered.
- [ ] Output allocation overflow is handled as a typed error.
- [ ] The public `MiniLMEmbedder` API and the C ABI remain unchanged.
- [ ] The fix passes on every architecture in the `companion-smoke` CI matrix.

### Verification

After provisioning the pinned model and native library:

```bash
swift test --package-path Packages/PKFastEmbed --filter PKFastEmbedTests.batch
swift test --package-path Packages/PKFastEmbed -c release --filter PKFastEmbedTests.batch
swift test --traits MiniLMEmbeddings --filter MiniLMEmbeddingContractTests.testBatchMatchesSingleEmbeddings
```

Run the equivalent package and contract tests in the Linux CI environment. Confirm that the logs show one batch bridge invocation for each nonempty batch test.

### Handoff Notes

Review the final unsafe code by tracing ownership from Swift allocation through the C call. Passing tests alone are insufficient evidence because the original dangling pointers commonly continue to reference apparently intact array storage.

---

## PKFAST-006: Validate Native Inference Shapes Before Copying Across the C ABI

**Priority:** P1  
**Type:** Native correctness and memory-safety defect  
**Depends on:** None  
**Blocks:** PKFastEmbed release qualification

### Summary

Validate every FastEmbed inference result before copying it into caller-owned memory. The current Rust bridge hard-codes 384 dimensions, removes the first single result without checking that it exists, flattens batch results without checking their count or individual dimensions, and then copies the expected number of floats. Unexpected native output can therefore panic or read beyond the source allocation.

### Current Problem

The single path assumes `guard.embed(vec![text], None)` returns exactly one vector containing at least `model.dimensions` values. `embeddings.remove(0)` panics when no result exists, and `ptr::copy_nonoverlapping(..., model.dimensions)` reads out of bounds when the vector is short.

The batch path assumes FastEmbed returns exactly `text_count` vectors and that every vector contains exactly 384 values. It flattens whatever was returned, then copies `model.dimensions * text_count` values even if the flattened source is shorter.

Although the higher-level PositronicKit service checks pinned model assets, `PKFastEmbed` is a public companion package and must safely reject malformed, incompatible, or unexpectedly shaped model output on its own.

### Files

- Modify: `Packages/PKFastEmbed/native/src/lib.rs`
- Modify: `Packages/PKFastEmbed/Tests/PKFastEmbedTests/PKFastEmbedTests.swift`
- Modify if new status values are necessary: `Packages/PKFastEmbed/native/include/pkfastembed.h`
- Keep synchronized if the header changes: `Packages/PKFastEmbed/Sources/CPKFastEmbed/include/pkfastembed.h`
- Modify if ABI constants or mappings change: `Packages/PKFastEmbed/Sources/PKFastEmbed/PKFastEmbed.swift`

### Implementation Requirements

1. For single inference, require exactly one returned embedding.
2. For batch inference, require exactly `text_count` returned embeddings.
3. Require every returned embedding to contain exactly `model.dimensions` floats. Do not silently truncate or zero-pad incompatible output.
4. Perform all validation before any output bytes are copied. On failure, leave the caller's output buffer unchanged.
5. Return `Status::InferenceFailed` with a stable diagnostic that includes expected and actual counts or dimensions without exposing Rust backtraces or internal paths.
6. Replace unchecked `model.dimensions * text_count` with `checked_mul`. Return `Status::InvalidArgument` when the requested output size overflows `usize`.
7. Ensure no Rust panic can cross an exported C function boundary. Wrap every exported function that executes fallible library or allocation logic with a consistent `catch_unwind` boundary, or document and prove an equivalent panic-free construction.
8. Convert a caught panic into a stable failure status and error message. Destructors must remain safe and idempotent for null pointers; callers are still responsible for passing each non-null handle exactly once.
9. Do not change the successful output layout: batch vectors remain contiguous in input order, with 384 `Float32` values per input for the pinned model.
10. If the C ABI changes, increment `PKFASTEMBED_ABI_VERSION` in both Rust and the public header and add an ABI mismatch test.

### Testability Requirement

The malformed-output branches must be directly testable without committing alternate model weights. Introduce a narrow Rust-internal inference adapter or test-only model implementation that can return:

- zero embeddings for a single input;
- too many embeddings for a single input;
- fewer and more embeddings than a requested batch;
- a vector shorter than 384;
- a vector longer than 384;
- a controlled panic.

Keep the production `TextEmbedding` integration behind the same internal contract. Do not expose test injection through the public C or Swift API.

### Required Tests

- Each malformed single result returns `PKFE_STATUS_INFERENCE_FAILED` without modifying the output buffer.
- Each malformed batch result returns `PKFE_STATUS_INFERENCE_FAILED` without modifying any part of the output buffer.
- Output-size overflow returns `PKFE_STATUS_INVALID_ARGUMENT` without allocation or inference.
- A controlled panic is contained and returned as a stable failure instead of unwinding across the C ABI or aborting the test process.
- Valid single and batch inference continue to match the pinned golden vector and normalization requirements.
- Invalid UTF-8 and undersized-buffer behavior remains unchanged.
- Native tests run under Miri where supported for the internal copy/validation helpers. If ONNX dependencies prevent a full Miri run, isolate pure validation and copy helpers into a Miri-compatible test target.
- Run the native suite with AddressSanitizer on at least Linux x86_64, or record a concrete toolchain blocker.

### Acceptance Criteria

- [ ] No vector is indexed, removed, flattened, or copied before its count and dimensions are validated.
- [ ] No source allocation can be read past its initialized length.
- [ ] Shape failure leaves the caller-provided output buffer unchanged.
- [ ] Integer overflow is rejected before allocation, slice construction, or pointer copying.
- [ ] Panics from bridge-owned or dependency code do not unwind through any exported C function.
- [ ] All failure paths return a stable status and an owned error string that callers can release with `pkfe_string_destroy`.
- [ ] Existing successful inference output remains byte-layout compatible unless an explicit ABI increment is required.
- [ ] The raw C API tests cover every newly introduced failure branch.

### Verification

```bash
cargo test --manifest-path Packages/PKFastEmbed/native/Cargo.toml --locked
cargo clippy --manifest-path Packages/PKFastEmbed/native/Cargo.toml --locked --all-targets -- -D warnings
swift test --package-path Packages/PKFastEmbed
swift test --traits MiniLMEmbeddings --filter MiniLMEmbeddingContractTests
```

Run the companion package tests across Linux x86_64/aarch64 and macOS arm64/x86_64. Confirm malformed-output tests complete normally and report statuses rather than signals, aborts, or sanitizer findings.

### Handoff Notes

Treat the C ABI as hostile-input code even though the primary caller is Swift. Pointer arguments must be validated as far as C permits, arithmetic must be checked, and Rust must not rely on higher-level model checksum validation for memory safety.

---

## PKFAST-007: Give the Native Model Handle Transactional Swift Ownership

**Priority:** P2  
**Type:** Resource-lifecycle defect  
**Depends on:** None  
**Blocks:** PKFastEmbed release qualification

### Summary

Ensure `MiniLMEmbedder.init(modelDirectory:)` destroys a native model handle when any operation after `pkfe_model_create` fails. The current initializer stores the raw handle in a partially initialized Swift object, then queries dimensions. If that query throws, Swift never completes object initialization and therefore never runs `deinit`, leaking the Rust `Model`, FastEmbed session, and ONNX Runtime resources.

### Current Problem

The initializer follows this sequence:

1. create the native model;
2. assign the returned pointer to `self.handle`;
3. query native dimensions;
4. assign `self.dimensions`.

An error during steps 3 or 4 exits before all stored properties are initialized. The object has no lifetime and `deinit` cannot release `self.handle`.

The current native implementation normally succeeds for a valid handle, but ABI mismatches, injected failures, future validation, or native defects can make the dimensions query fail. Ownership must remain correct for every status returned by the C API.

### Files

- Modify: `Packages/PKFastEmbed/Sources/PKFastEmbed/PKFastEmbed.swift`
- Modify: `Packages/PKFastEmbed/Tests/PKFastEmbedTests/PKFastEmbedTests.swift`
- Modify native test support if required: `Packages/PKFastEmbed/native/src/lib.rs`

### Implementation Requirements

1. Keep the newly created raw handle under temporary local ownership until all throwing initialization work succeeds.
2. Install cleanup immediately after confirming the create call returned a non-null handle.
3. Cancel temporary cleanup only after `handle` and `dimensions` have both been established successfully.
4. Continue to destroy the handle exactly once from `deinit` after successful initialization.
5. Do not represent ownership with multiple independent booleans that can drift out of sync. Prefer a small RAII owner or a tightly scoped `defer` with an explicit transfer flag.
6. Reject a native dimension of zero with `PKFastEmbedError.modelLoadFailed` or a more specific existing initialization error, and release the handle.
7. Reject dimensions that cannot be represented safely by Swift output allocation, and release the handle.
8. Preserve the public initializer and error enum unless a new error case is demonstrably necessary.
9. Do not make `handle` optional for the entire successful object lifetime solely to simplify partial initialization.

### Testability Requirement

Add a deterministic test mechanism that makes model creation return a tracked handle and makes the subsequent dimensions query fail. The test mechanism must also expose or assert the matching destroy count. Keep this injection internal to the package tests; do not add process-wide environment switches or public API solely for testing.

### Required Tests

- Successful initialization destroys the native handle exactly once when the Swift object is released.
- A dimensions-query failure after successful model creation destroys the handle exactly once.
- A zero-dimension response destroys the handle exactly once and returns the selected initialization error.
- A model-create failure does not invoke destroy for a null or nonexistent handle.
- Repeated failed initialization does not produce unbounded native memory growth in a focused stress test.
- Existing missing-directory and valid-model tests continue to pass.

### Acceptance Criteria

- [ ] Every non-null handle returned by `pkfe_model_create` has one clear owner immediately after creation.
- [ ] Every initializer exit path either transfers the handle into a fully initialized `MiniLMEmbedder` or destroys it exactly once.
- [ ] `deinit` remains the sole destruction path for successfully initialized instances.
- [ ] Zero and invalid dimensions are rejected before allocating embedding buffers.
- [ ] Resource-lifecycle tests deterministically exercise both successful transfer and failed initialization.
- [ ] No public API or process-global test configuration is introduced for dependency injection.

### Verification

```bash
swift test --package-path Packages/PKFastEmbed --filter PKFastEmbedTests.initialization
swift test --package-path Packages/PKFastEmbed
```

Run the focused failure loop with leak detection on macOS and Linux. Record the tool and result in the ticket outcome; acceptable tools include Instruments/Leaks on macOS and LeakSanitizer or Valgrind on Linux.

### Handoff Notes

Keep the ownership transfer visible in a short initializer. The review criterion is not merely that a `defer` exists, but that a reader can prove exactly one destruction for every create result and every throwing path.

---

## Completion Order and Release Gate

1. Implement **PKFAST-005** and **PKFAST-006** independently; both are P1 release blockers.
2. Implement **PKFAST-007** before tagging or publishing the companion package.
3. Run the full companion architecture matrix and the PositronicKit MiniLM contract suite after all three changes are integrated.
4. Do not close the parent Linux embedding follow-up until sanitizer or leak-check evidence is attached, or until concrete toolchain limitations and compensating tests are documented.

The release gate is satisfied only when all acceptance criteria above pass without relying on higher-level PositronicKit checksum validation to make the native bridge memory-safe.
