import Foundation
@testable import PKShared
import Testing

/// Coverage for `EmbeddingInputBudget` validation and its `ValidationError` round-tripping.
///
/// The budget enforces three independent limits (text count, per-text bytes, total batch
/// bytes) before embedding inference. The `ValidationError` enum also carries a
/// message-parser initializer used to reconstruct the error from a provider/bridge error
/// string — that parser was previously untested.
@Suite("EmbeddingInputBudget")
struct EmbeddingInputBudgetTests {

    // MARK: - Validation

    @Test("Default budget accepts normal-sized inputs")
    func defaultBudgetAcceptsNormalInput() throws {
        let budget = EmbeddingInputBudget.default
        try budget.validate("a normal short string")
        try budget.validate(["one", "two", "three"])
    }

    @Test("Rejects a batch exceeding the text-count limit")
    func rejectsBatchTextCount() {
        let budget = EmbeddingInputBudget(maxTextCount: 2, maxBytesPerText: 100, maxTotalBytes: 1000)
        #expect(throws: EmbeddingInputBudget.ValidationError.batchTextCountLimitExceeded(max: 2, actual: 3)) {
            try budget.validate(["a", "b", "c"])
        }
    }

    @Test("Rejects a single text exceeding the per-text byte limit")
    func rejectsPerTextByteLimit() {
        let budget = EmbeddingInputBudget(maxTextCount: 10, maxBytesPerText: 5, maxTotalBytes: 100)
        let longText = String(repeating: "x", count: 10)
        #expect(throws: EmbeddingInputBudget.ValidationError.perTextByteLimitExceeded(max: 5, actual: 10)) {
            try budget.validate(longText)
        }
    }

    @Test("Rejects a batch exceeding the total byte limit")
    func rejectsTotalBatchByteLimit() {
        let budget = EmbeddingInputBudget(maxTextCount: 10, maxBytesPerText: 100, maxTotalBytes: 9)
        #expect(throws: EmbeddingInputBudget.ValidationError.totalBatchByteLimitExceeded(max: 9, actual: 10)) {
            try budget.validate(["hello", "world"])
        }
    }

    @Test("Counts UTF-8 bytes, not character count")
    func countsUTF8Bytes() {
        let budget = EmbeddingInputBudget(maxTextCount: 10, maxBytesPerText: 3, maxTotalBytes: 100)
        // "é" is 2 UTF-8 bytes, 1 character.
        #expect(throws: EmbeddingInputBudget.ValidationError.perTextByteLimitExceeded(max: 3, actual: 4)) {
            try budget.validate("éé")
        }
    }

    @Test("Empty batch passes validation")
    func emptyBatchPasses() throws {
        let budget = EmbeddingInputBudget(maxTextCount: 1, maxBytesPerText: 1, maxTotalBytes: 1)
        try budget.validate([])
    }

    @Test("Single-text validate overload delegates to the batch overload")
    func singleTextOverload() throws {
        let budget = EmbeddingInputBudget(maxTextCount: 10, maxBytesPerText: 5, maxTotalBytes: 100)
        try budget.validate("ok")
        #expect(throws: EmbeddingInputBudget.ValidationError.perTextByteLimitExceeded(max: 5, actual: 10)) {
            try budget.validate(String(repeating: "x", count: 10))
        }
    }

    // MARK: - ValidationError message round-tripping

    @Test("ValidationError reconstructs from a batch-text-count message")
    func reconstructsBatchTextCountMessage() {
        let original = EmbeddingInputBudget.ValidationError.batchTextCountLimitExceeded(max: 64, actual: 100)
        let reconstructed = EmbeddingInputBudget.ValidationError(message: original.message)
        #expect(reconstructed == original)
    }

    @Test("ValidationError reconstructs from a per-text-byte message")
    func reconstructsPerTextByteMessage() {
        let original = EmbeddingInputBudget.ValidationError.perTextByteLimitExceeded(max: 65536, actual: 100000)
        let reconstructed = EmbeddingInputBudget.ValidationError(message: original.message)
        #expect(reconstructed == original)
    }

    @Test("ValidationError reconstructs from a total-batch-byte message")
    func reconstructsTotalBatchByteMessage() {
        let original = EmbeddingInputBudget.ValidationError.totalBatchByteLimitExceeded(max: 262144, actual: 500000)
        let reconstructed = EmbeddingInputBudget.ValidationError(message: original.message)
        #expect(reconstructed == original)
    }

    @Test("ValidationError returns nil for an unrecognized message")
    func unrecognizedMessageReturnsNil() {
        let reconstructed = EmbeddingInputBudget.ValidationError(message: "something completely different")
        #expect(reconstructed == nil)
    }

    @Test("ValidationError returns nil for a partially-matching message")
    func partiallyMatchingMessageReturnsNil() {
        // Right prefix but non-integer values.
        let msg = "Embedding input exceeded the batch text-count limit of abc item(s) (def provided)."
        #expect(EmbeddingInputBudget.ValidationError(message: msg) == nil)
    }

    @Test("ValidationError.message matches the canonical limit-message format")
    func validationMessageMatchesCanonicalFormat() {
        // The ValidationError.message strings are intentionally identical to the
        // EmbeddingError.userFriendlyMessage strings so the bridge can reconstruct the
        // typed ValidationError from an EmbeddingError's message. Verify the canonical
        // format here without crossing into the PositronicKit module.
        let batchCount = EmbeddingInputBudget.ValidationError.batchTextCountLimitExceeded(max: 64, actual: 100)
        #expect(batchCount.message == "Embedding input exceeded the batch text-count limit of 64 item(s) (100 provided).")

        let perText = EmbeddingInputBudget.ValidationError.perTextByteLimitExceeded(max: 100, actual: 200)
        #expect(perText.message == "Embedding input exceeded the per-text byte limit of 100 bytes (200 bytes provided).")

        let totalBatch = EmbeddingInputBudget.ValidationError.totalBatchByteLimitExceeded(max: 1000, actual: 2000)
        #expect(totalBatch.message == "Embedding input exceeded the total batch byte limit of 1000 bytes (2000 bytes provided).")
    }
}
