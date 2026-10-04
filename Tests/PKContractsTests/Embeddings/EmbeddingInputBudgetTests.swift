import Foundation
import PKContracts
import Testing

@Suite("EmbeddingInputBudget")
struct EmbeddingInputBudgetTests {
    @Test("Default budget accepts normal-sized inputs")
    func defaultBudgetAcceptsNormalInput() throws {
        let budget = EmbeddingInputBudget.default
        try budget.validate("a normal short string")
        try budget.validate(["one", "two", "three"])
    }

    @Test("Rejects a batch exceeding the text-count limit")
    func rejectsBatchTextCount() {
        let budget = EmbeddingInputBudget(maxTextCount: 2, maxBytesPerText: 100, maxTotalBytes: 1000)
        #expect(throws: EmbeddingError.batchTextCountLimitExceeded(max: 2, actual: 3)) {
            try budget.validate(["a", "b", "c"])
        }
    }

    @Test("Rejects a single text exceeding the per-text byte limit")
    func rejectsPerTextByteLimit() {
        let budget = EmbeddingInputBudget(maxTextCount: 10, maxBytesPerText: 5, maxTotalBytes: 100)
        #expect(throws: EmbeddingError.perTextByteLimitExceeded(max: 5, actual: 10)) {
            try budget.validate(String(repeating: "x", count: 10))
        }
    }

    @Test("Rejects a batch exceeding the total byte limit")
    func rejectsTotalBatchByteLimit() {
        let budget = EmbeddingInputBudget(maxTextCount: 10, maxBytesPerText: 100, maxTotalBytes: 9)
        #expect(throws: EmbeddingError.totalBatchByteLimitExceeded(max: 9, actual: 10)) {
            try budget.validate(["hello", "world"])
        }
    }

    @Test("Counts UTF-8 bytes, not character count")
    func countsUTF8Bytes() {
        let budget = EmbeddingInputBudget(maxTextCount: 10, maxBytesPerText: 3, maxTotalBytes: 100)
        #expect(throws: EmbeddingError.perTextByteLimitExceeded(max: 3, actual: 4)) {
            try budget.validate("éé")
        }
    }

    @Test("Empty batch passes validation")
    func emptyBatchPasses() throws {
        let budget = EmbeddingInputBudget(maxTextCount: 1, maxBytesPerText: 1, maxTotalBytes: 1)
        try budget.validate([])
    }

    @Test("Batches split on the text-count boundary")
    func batchesSplitOnCount() throws {
        let budget = EmbeddingInputBudget(maxTextCount: 2, maxBytesPerText: 100, maxTotalBytes: 1000)
        let batches = try budget.batches(["a", "b", "c", "d", "e"])
        #expect(batches == [["a", "b"], ["c", "d"], ["e"]])
    }

    @Test("Batches split on the total-byte boundary")
    func batchesSplitOnBytes() throws {
        let budget = EmbeddingInputBudget(maxTextCount: 10, maxBytesPerText: 100, maxTotalBytes: 5)
        let batches = try budget.batches(["aa", "bb", "cc"])
        #expect(batches == [["aa", "bb"], ["cc"]])
    }

    @Test("Batches reject a single text over the per-text limit")
    func batchesRejectOversizedText() {
        let budget = EmbeddingInputBudget(maxTextCount: 10, maxBytesPerText: 2, maxTotalBytes: 100)
        #expect(throws: EmbeddingError.perTextByteLimitExceeded(max: 2, actual: 3)) {
            try budget.batches(["aa", "bbb"])
        }
    }

    @Test("Empty input yields no batches")
    func emptyInputYieldsNoBatches() throws {
        let budget = EmbeddingInputBudget(maxTextCount: 2, maxBytesPerText: 10, maxTotalBytes: 10)
        #expect(try budget.batches([]).isEmpty)
    }
}
