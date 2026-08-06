# PKEMBED-002: Implement MiniLM on Linux and Trait-Enabled Apple Builds

**Priority:** P1  
**Type:** Feature  
**Depends on:** PKFAST-001  
**Blocks:** PKCI-003, PKDOC-004  
**Status:** Done

### Summary

Replace the non-Apple `platformNotSupported` stub with fixed, in-process MiniLM inference. Add the approved additive `MiniLMEmbeddings` SwiftPM trait so macOS can explicitly build and test the same backend while preserving Natural Language as the default Apple implementation.

### Current Problem

- `Sources/PKLocalEmbeddings/LocalEmbeddingService.swift` throws `EmbeddingError.platformNotSupported` whenever Natural Language is unavailable.
- `Tests/PositronicKitTests/EmbeddingServiceTests.swift` currently treats that Linux failure as success.
- `Package.swift` declares Swift tools 6.1 but has no traits or MiniLM backend dependencies.

### Completion Note

`MiniLMEmbeddings` trait now declared in `Package.swift`. `LocalEmbeddingService` on Linux uses MiniLM backend via `PKFastEmbed`. Apple default preserves Natural Language. Trait-enabled Apple builds support explicit MiniLM construction. Contract tests pass across platforms.

Safety follow-ups tracked in PKFAST-005, PKFAST-006, PKFAST-007.
