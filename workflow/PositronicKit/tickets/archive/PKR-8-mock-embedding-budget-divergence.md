# PKR-8 — `MockEmbeddingService` doesn't enforce `EmbeddingInputBudget`, diverging from real services

**Status:** Done
**Severity:** 🟠 Medium (mock/production contract divergence — YAK-38 class)
**Repos:** PositronicKit (PKTestSupport)
**Source:** PositronicKit review 2026-07-02

## Problem

`Tests/PKTestSupport/MockEmbeddingService.swift:12-41`: `generateEmbedding(s)` return vectors
unconditionally, never calling `EmbeddingInputBudget.validate` — unlike the real
`LocalEmbeddingService` (`Sources/PKLocalEmbeddings/LocalEmbeddingService.swift:59-67`) and
`MiniLMEmbedder.embed` (`Sources/PKFastEmbed/PKFastEmbed.swift:119-173`), which both validate
first (YAK-36). Tests composed on the mock cannot observe budget rejections, so a production
regression dropping the check would go uncaught. Same divergence class as the fixed
`MockLocalWorkspace` sanitizer gap (YAK-38).

## Suggested direction

Give `MockEmbeddingService` an injectable `EmbeddingInputBudget` (default `.default`) and throw
the same `EmbeddingError` mapping as `LocalEmbeddingService.mapValidationError`. Add a mock-level
test mirroring the real budget-rejection tests.

## Resolution (2026-07-04)

`MockEmbeddingService` now accepts an `EmbeddingInputBudget` (default `.default` so existing tests
are unaffected) and calls `inputBudget.validate(...)` before returning mock vectors in both
`generateEmbedding(for:)` and `generateEmbeddings(for:)`. `EmbeddingInputBudget.ValidationError` is
mapped to `EmbeddingError` via the same switch as `LocalEmbeddingService.mapValidationError`.

Added 4 mock-level budget tests (`MockEmbeddingServiceBudgetTests.swift`):
- Single-text per-text byte limit rejection.
- Batch text-count limit rejection.
- Batch total-byte limit rejection.
- Default budget allows normal-sized inputs (no regression).

690 PositronicKit tests green.
