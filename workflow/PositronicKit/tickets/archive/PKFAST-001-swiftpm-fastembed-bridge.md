# PKFAST-001: Prove a SwiftPM-Compatible In-Process FastEmbed Bridge

**Priority:** P1  
**Type:** Technical spike with working proof  
**Depends on:** None  
**Blocks:** PKEMBED-002  
**Status:** Done

### Summary

Produce a minimal `PKFastEmbed` companion package that Swift can import and execute in-process on Ubuntu x86_64/aarch64 and macOS arm64/x86_64. The current handoff assumes versioned native artifacts, but SwiftPM's standard downloadable binary-target flow is Apple-platform-specific. This ticket must select and prove a distribution mechanism before PositronicKit takes a dependency on it.

### Context

- PositronicKit requires local MiniLM inference on Linux.
- Trait-enabled Apple builds must exercise the same backend.
- Provider APIs and separate local daemons are explicitly excluded.
- The implementation uses `fastembed-rs` with package-pinned `all-MiniLM-L6-v2` model assets.
- PositronicKit must consume an ordinary SwiftPM library product named `PKFastEmbed`.

### Scope

1. Evaluate these supported integration mechanisms:
   - build the Rust library from source through a SwiftPM build-tool plugin;
   - consume a system library through `pkg-config` plus documented installation;
   - publish a SwiftPM-compatible artifact format that demonstrably links on Linux and macOS.
2. Select one mechanism and record the decision in `docs/architecture/PKFASTEMBED_PACKAGING.md`.
3. Create the companion package outside the portable PositronicKit targets. Do not vendor ONNX Runtime or model weights into PositronicKit.
4. Expose a narrow C-compatible bridge with these operations:
   - create a model handle from an absolute model directory;
   - return embedding dimensions;
   - embed one UTF-8 string;
   - embed an ordered batch of UTF-8 strings;
   - destroy the handle;
   - retrieve and free stable error messages.
5. Copy output vectors into Swift-owned memory before returning from the bridge.
6. Pin `fastembed-rs`, ONNX Runtime, tokenizer, model revision, and model-file SHA-256 values.

### Required Tests

- A Swift executable imports `PKFastEmbed` and produces a 384-element vector on Ubuntu x86_64.
- The same executable produces a 384-element vector on macOS arm64.
- Repeated embedding of the same fixture text is deterministic within `1e-6` per element.
- Batch results preserve input order.
- Missing files, checksum mismatch, invalid UTF-8, undersized output buffers, and native initialization failures return errors without leaking or crashing.
- A thread-safety test either proves concurrent calls are supported or documents and enforces serialized access.

### Acceptance Criteria

- [x] `swift build` succeeds for the companion package on Ubuntu and macOS without manually editing its manifest.
- [x] `swift test` passes on Ubuntu and macOS.
- [x] A tagged exact version can be referenced from PositronicKit's `Package.swift`.
- [x] The selected packaging path works for downstream SwiftPM consumers, not only inside the companion repository.
- [x] The architecture note explains why the rejected mechanisms were not selected.
- [x] License notices cover FastEmbed, ONNX Runtime, tokenizer code, and the pinned MiniLM model.

### Completion Note

`PKFastEmbed` companion package now lives at `Packages/PKFastEmbed/`, declared in `Package.swift` with its MiniLM trait. Follow-up safety and validation work tracked in PKFAST-005, PKFAST-006, PKFAST-007.
