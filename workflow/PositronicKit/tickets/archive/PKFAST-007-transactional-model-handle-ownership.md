# PKFAST-007: Give the Native Model Handle Transactional Swift Ownership

**Priority:** P2  
**Type:** Resource-lifecycle defect  
**Depends on:** None  
**Blocks:** PKFastEmbed release qualification  
**Status:** Closed as already landed on `main` before 2026-07-04 review

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

### Implementation Requirements

1. Keep the newly created raw handle under temporary local ownership until all throwing initialization work succeeds.
2. Install cleanup immediately after confirming the create call returned a non-null handle.
3. Cancel temporary cleanup only after `handle` and `dimensions` have both been established successfully.
4. Continue to destroy the handle exactly once from `deinit` after successful initialization.
5. Do not represent ownership with multiple independent booleans that can drift out of sync. Prefer a small RAII owner or a tightly scoped `defer` with an explicit transfer flag.
6. Reject a native dimension of zero with `PKFastEmbedError.modelLoadFailed` or a more specific existing initialization error, and release the handle.
7. Preserve the public initializer and error enum unless a new error case is demonstrably necessary.
8. Do not make `handle` optional for the entire successful object lifetime solely to simplify partial initialization.

### Required Tests

- Successful initialization destroys the native handle exactly once when the Swift object is released.
- A dimensions-query failure after successful model creation destroys the handle exactly once.
- A zero-dimension response destroys the handle exactly once and returns the selected initialization error.
- A model-create failure does not invoke destroy for a null or nonexistent handle.
- Repeated failed initialization does not produce unbounded native memory growth in a focused stress test.

### Acceptance Criteria

- [x] Every non-null handle returned by `pkfe_model_create` has one clear owner immediately after creation.
- [x] Every initializer exit path either transfers the handle into a fully initialized `MiniLMEmbedder` or destroys it exactly once.
- [x] `deinit` remains the sole destruction path for successfully initialized instances.
- [x] Zero and invalid dimensions are rejected before allocating embedding buffers.
- [x] Resource-lifecycle tests deterministically exercise both successful transfer and failed initialization.
- [x] No public API or process-global test configuration is introduced for dependency injection.

### Review Notes

- Ticket review on 2026-07-04 found the expected ownership transfer already present in
  `PKFastEmbed` on `main`, with the corresponding lifecycle tests already landed.
- No source changes were required in the current batch, so this ticket was replaced by
  `PKINT-004` for the "another 3" implementation pass.
