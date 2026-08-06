# PKDEEP-005-impl — Collapse embeddings tower into one deep facade

**Priority:** P3
**Type:** Implementation (deepening)
**Depends on:** PKDEEP-005 (research, done)
**Blocks:** none
**Triage:** ready-for-agent
**Status:** Done (2026-07-08, commit `307b22c`)

### Summary

Collapse `LocalEmbeddingBackend` (47 lines), `MiniLMEmbeddingBackend` (51 lines), and
`NaturalLanguageEmbeddingBackend` (38 lines) into `LocalEmbeddingService`. The unified
service implements `EmbeddingServiceProtocol` directly with platform-conditional code paths.
Keeps `PKMiniLMPlatformBackend` and `MiniLMEmbedder` (PKFastEmbed) unchanged as the deep
native bridge.

### Implementation requirements

1. **Inline `LocalEmbeddingBackend` into `LocalEmbeddingService`**: Replace the
   `private let backend: LocalEmbeddingBackend` field with platform-conditional stored
   properties:
   - `#if os(Linux) || MiniLMEmbeddings`: `private let miniLMBackend: PKMiniLMPlatformBackend?`
   - On macOS without trait: `miniLMBackend` is `nil` (NL path)
   - Or use a single optional `PKMiniLMPlatformBackend?` across all platforms

2. **Inline `MiniLMEmbeddingBackend` logic**: The `MiniLMModelAssets.validate(modelDirectory:)`
   call and `PKMiniLMPlatformBackend` construction move into `LocalEmbeddingService.init`
   (the existing MiniLM init paths). The `#if os(Linux) || MiniLMEmbeddings` conditionals
   stay on the stored property and init body.

3. **Inline `NaturalLanguageEmbeddingBackend` logic**: The `NLEmbedding.sentenceEmbedding(for:)`
   logic moves into `LocalEmbeddingService.generateEmbedding(for:)` / `generateEmbeddings(for:)`
   under `#if canImport(NaturalLanguage)`.

4. **Update `generateEmbedding`/`generateEmbeddings` methods**: After validation, dispatch:
   - If `miniLMBackend != nil`: `try await miniLMBackend!.generateEmbedding(for: text)`
   - Else: inline `NLEmbedding` code (the `#if canImport(NaturalLanguage)` / `#else` throw
     `EmbeddingError.modelUnavailable`)

5. **Simplify `backendIdentifier`**: Return `.miniLM` if `miniLMBackend != nil`, else
   `.naturalLanguage`. Keep `LocalEmbeddingBackendKind` as the return type (or inline as
   a string/enum on `LocalEmbeddingService`).

6. **Simplify `backendInputBudget`**: Just return `inputBudget` — the
   `MiniLMEmbeddingBackend.inputBudget` is always the same value passed through.

7. **Delete files**: `LocalEmbeddingBackend.swift`, `MiniLMEmbeddingBackend.swift`,
   `NaturalLanguageEmbeddingBackend.swift`. Keep `LocalEmbeddingService.swift` (now larger),
   `PKMiniLMPlatformBackend.swift` (unchanged), `PKFastEmbed.swift` / `MiniLMEmbedder`
   (unchanged).

8. **Preserve public init signatures byte-identically**:
   - `init(modelDirectory:inputBudget:)` — Linux
   - `init(inputBudget:)` — macOS default
   - `init(miniLMModelDirectory:inputBudget:)` — macOS with trait

9. **Update tests**: Recast `testMiniLMBackendUsesConfiguredBudgetAndPreservesTypedLimitError`
   in `MiniLMEmbeddingContractTests.swift` (line ~126) to construct `LocalEmbeddingService`
   instead of `MiniLMEmbeddingBackend` directly. All other tests go through the protocol
   seam and are unchanged.

### Acceptance criteria

- [ ] `LocalEmbeddingBackend.swift`, `MiniLMEmbeddingBackend.swift`,
      `NaturalLanguageEmbeddingBackend.swift` deleted
- [ ] `LocalEmbeddingService` implements `EmbeddingServiceProtocol` directly with
      platform-conditional code paths
- [ ] `PKMiniLMPlatformBackend` and `MiniLMEmbedder` unchanged
- [ ] Public init signatures byte-identical
- [ ] `backendIdentifier` and `backendInputBudget` still work (or simplified)
- [ ] 1 test recast; all other tests unchanged
- [ ] `make verify` green

### Downstream sync

All affected symbols are `package`-internal except `LocalEmbeddingService`'s public inits.
Only downstream reference: `LocalEmbeddingService()` in `MonadServerFactory.swift:239`.
No coordination needed if init signatures are preserved.

### Verification

```bash
cd PositronicKit
make verify
```

### Cross-links

- Research: [PKDEEP-005](../PKDEEP-005-embeddings-tower-collapse.md)
