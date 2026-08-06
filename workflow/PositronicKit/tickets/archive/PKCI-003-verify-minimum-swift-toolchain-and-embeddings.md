# PKCI-003: Test the Minimum Swift Toolchain and Every Embedding Configuration

**Priority:** P2  
**Type:** Makefile hardening  
**Depends on:** PKEMBED-002 for MiniLM jobs; minimum-toolchain work can start independently  
**Blocks:** PKDOC-004  
**Status:** Closed

### Summary

Make the package's verification gates validate the declared Swift 6.1 minimum and all supported local-embedding build configurations. The current `make` targets already drive the core package gates plus the MiniLM verification path, but they still need the minimum-toolchain axis and the full every-embedding-configuration coverage.

### Current State

`PositronicKit/Makefile` now runs `verify`, `verify-products`, and `verify-minilm` across the three package roots. The remaining work is to add the minimum-toolchain verification path and any missing per-configuration build commands so the make-based matrix matches the package matrix instead of only the core gates.

### Required Verification Matrix

1. **Minimum Linux:** Ubuntu 24.04 with Swift 6.1.3.
2. **Current Linux:** Ubuntu 24.04 with Swift 6.3.2.
3. **Default macOS:** repository's supported Xcode, no traits.
4. **MiniLM macOS:** same Xcode with `MiniLMEmbeddings` enabled and cached pinned model assets.

### Acceptance Criteria

- [x] Swift 6.1.3 and Swift 6.3.2 Linux jobs both pass.
- [x] Every product classified as Linux-supported has an explicit build command.
- [x] Linux local-embedding tests perform real inference; they do not assert an unsupported-platform error.
- [x] Default macOS verification proves `PKFastEmbed` is absent from the linked product.
- [x] Trait-enabled macOS verification runs the MiniLM contract suite.
- [x] Model cache keys include the exact model SHA-256 so stale assets cannot be reused.
- [x] Required verification coverage includes the minimum Linux, current Linux, default macOS, and MiniLM macOS targets.

### Progress Note (2026-07-04)

The Makefile now exposes explicit gate names for the documented matrix:
`verify-macos-default`, `verify-macos-minilm`, `verify-linux-minimum`, and
`verify-linux-current` (with `verify-linux` aliased to the current Linux gate).
`verify-products` now expands into one explicit `swift build --product ...`
command per product, and the default MiniLM model cache directory is keyed by
the pinned `model.onnx` SHA-256 to prevent stale-asset reuse. `bootstrap-minilm`
receives that checksum-keyed directory through `PK_MINILM_MODEL_DIR`.

Local verification now also includes real macOS host passes for
`make verify-macos-default` and `make verify-macos-minilm` on July 4, 2026, in
addition to `make verify-pin` and the earlier dry-run matrix expansion
(`make -n verify-linux-base`, `make -n verify-products`,
`make -n verify-macos-default`). The repo also now exposes
`make verify-linux-asan` for the separate bridge-only sanitizer requirement.

Ubuntu 24.04 host execution was later completed by the user for both
`verify-linux-minimum` and `verify-linux-current`, satisfying the remaining
Linux host-matrix evidence. This ticket is closed.
