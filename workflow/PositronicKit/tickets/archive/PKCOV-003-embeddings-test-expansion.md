# PKCOV-003 — Expand embeddings test coverage (PKLocalEmbeddings / PKFastEmbed)

**Priority:** P2
**Type:** Test coverage
**Depends on:** PKFLAKE-004 (concurrency contract decided first)
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `d60ab59`) — the ticket's original wishlist was mostly already
closed by PKFLAKE-004/006 (which landed first): `NaturalLanguageEmbeddingTests.swift` already had 7
tests (default, non-gated, availability-skip-gated) and `PKFastEmbedTests`/`PKFastEmbedBatchTests`
already had 21 tests (MiniLM-trait-gated). Remaining real gaps closed: a batch-vs-single-embedding
consistency test for the Natural Language backend specifically (MiniLM-gated tests already had the
equivalent; NL path didn't), a single-item-batch native-inference test, and a batch
output-dimension-invariant test across varied sizes (1/2/5/10/33) for `PKFastEmbedBatchTests`. The
`modelUnavailable` error path remains genuinely untestable without adding a new seam to
`LocalEmbeddingService.naturalLanguageEmbedding(for:)` (hardcoded `NLEmbedding.sentenceEmbedding`
call, no injection point) — left as-is per the ticket's own "otherwise skip-gated" allowance; adding
a seam would be a larger change than this ticket's scope. Default `swift test`: 903 tests / 157
suites green (no network/model downloads). `make verify-minilm`: 23 tests / 2 suites green.

### Summary

The embeddings targets are nearly untested: `PKLocalEmbeddingsTests` has 3 tests,
`PKFastEmbedTests` 2 (plus the MiniLM-gated suite behind `make verify-minilm`). Given
`LocalEmbeddingService` was just collapsed (PKDEEP-005-impl) and PKFLAKE-004 flags a
concurrency question in `MiniLMEmbedder`, this surface needs real coverage before a
stable release.

### Implementation Requirements

1. `LocalEmbeddingService` (`Sources/PKLocalEmbeddings/LocalEmbeddingService.swift`):
   - input-budget enforcement (over-budget input behavior pinned),
   - backend selection (`backendIdentifier` on this platform; MiniLM vs
     NaturalLanguage path),
   - `modelUnavailable` error path (inject/simulate unavailable `NLEmbedding` where
     possible; otherwise skip-gated),
   - batch vs single embedding consistency.
2. `PKFastEmbed`:
   - batch edge cases: empty batch, single item, large batch, non-ASCII/UTF-8-heavy
     inputs (regression area per PKFAST-005),
   - concurrent embed calls (once PKFLAKE-004 defines the contract),
   - dimension/shape invariants on outputs.
3. Keep model-downloading tests behind the existing `verify-minilm` gate; default
   `swift test` must stay hermetic.

### Acceptance Criteria

- [x] PKLocalEmbeddingsTests ≥ 10 behavioral tests; PKFastEmbedTests meaningfully
      expanded (≥ 8 in the non-gated or gated suites as appropriate).
- [x] No network/model downloads in default `swift test`.
- [x] `make verify` green; `make verify-minilm` green where runnable.
