import Foundation
import PKShared
import PKUtilities
import PKTestSupport
import PositronicKit
import Testing

@Suite("MockEmbeddingService budget enforcement (PKR-8)")
struct MockEmbeddingServiceBudgetTests {
    @Test("Single-text embedding respects per-text byte limit")
    func singleTextPerByteLimit() async throws {
        let service = MockEmbeddingService(
            inputBudget: EmbeddingInputBudget(maxTextCount: 10, maxBytesPerText: 10, maxTotalBytes: 100)
        )

        let ok = try await service.generateEmbedding(for: "short")
        #expect(!ok.isEmpty)

        let longText = String(repeating: "x", count: 20)
        await #expect(throws: EmbeddingError.perTextByteLimitExceeded(max: 10, actual: 20)) {
            try await service.generateEmbedding(for: longText)
        }
    }

    @Test("Batch embeddings respect batch text-count limit")
    func batchTextCountLimit() async throws {
        let service = MockEmbeddingService(
            inputBudget: EmbeddingInputBudget(maxTextCount: 2, maxBytesPerText: 100, maxTotalBytes: 1000)
        )

        let ok = try await service.generateEmbeddings(for: ["a", "b"])
        #expect(ok.count == 2)

        await #expect(throws: EmbeddingError.batchTextCountLimitExceeded(max: 2, actual: 3)) {
            try await service.generateEmbeddings(for: ["a", "b", "c"])
        }
    }

    @Test("Batch embeddings respect total batch byte limit")
    func batchTotalByteLimit() async throws {
        // "hello" (5 bytes) + "world" (5 bytes) = 10 total bytes; cap at 9 to trigger rejection.
        let service = MockEmbeddingService(
            inputBudget: EmbeddingInputBudget(maxTextCount: 10, maxBytesPerText: 100, maxTotalBytes: 9)
        )

        await #expect(throws: EmbeddingError.totalBatchByteLimitExceeded(max: 9, actual: 10)) {
            try await service.generateEmbeddings(for: ["hello", "world"])
        }
    }

    @Test("Default budget allows normal-sized inputs (no regression)")
    func defaultBudgetAllowsNormalInput() async throws {
        let service = MockEmbeddingService()

        let vec = try await service.generateEmbedding(for: "Hello world")
        #expect(!vec.isEmpty)

        let vecs = try await service.generateEmbeddings(for: ["Apple", "Banana", "Orange"])
        #expect(vecs.count == 3)
    }
}
