import Foundation
@testable import PKLocalEmbeddings
import PKShared
import PositronicKit
import Testing

#if canImport(NaturalLanguage)
@Suite("Natural Language embeddings")
struct NaturalLanguageEmbeddingTests {
    private let service = LocalEmbeddingService()

    @Test("Default Apple construction uses Natural Language")
    func defaultAppleConstructionUsesNaturalLanguage() async throws {
        let vector = try await service.generateEmbedding(for: "Hello world")

        #expect(service.backendIdentifier == .naturalLanguage)
        #expect(vector.count == 512)
    }

    @Test("Batch ordering is preserved for the Apple backend")
    func batchOrderingIsPreserved() async throws {
        let texts = ["Apple", "Banana", "Orange"]
        let vectors = try await service.generateEmbeddings(for: texts)

        #expect(vectors.count == texts.count)
        #expect(vectors.allSatisfy { $0.count == 512 })
    }

    @Test("Natural Language results are deterministic for a single process")
    func deterministicPerProcess() async throws {
        let first = try await service.generateEmbedding(for: "A stable fixture sentence.")
        let second = try await service.generateEmbedding(for: "A stable fixture sentence.")

        #expect(first.count == second.count)
        #expect(zip(first, second).allSatisfy { abs($0 - $1) < 0.000_001 })
    }

    @Test("Natural Language backend rejects text over the default byte limit")
    func rejectsTextOverDefaultByteLimit() async throws {
        let text = String(repeating: "a", count: EmbeddingBudgetFixture.maxBytesPerText + 1)

        await assertLimitError(
            expectedSnippet: "per-text byte limit"
        ) {
            _ = try await service.generateEmbedding(for: text)
        }
    }

    @Test("Natural Language backend rejects a single text over a custom total-byte limit")
    func rejectsSingleTextOverCustomTotalByteLimit() async throws {
        let service = LocalEmbeddingService(
            inputBudget: EmbeddingInputBudget(maxTextCount: 4, maxBytesPerText: 10, maxTotalBytes: 5)
        )

        await assertLimitError(
            expectedSnippet: "total batch byte limit"
        ) {
            _ = try await service.generateEmbedding(for: "123456")
        }
    }

    @Test("Natural Language backend rejects batches over the default text-count limit")
    func rejectsBatchOverDefaultTextCountLimit() async throws {
        let texts = Array(repeating: "a", count: EmbeddingBudgetFixture.maxTextCount + 1)

        await assertLimitError(
            expectedSnippet: "batch text-count limit"
        ) {
            _ = try await service.generateEmbeddings(for: texts)
        }
    }

    @Test("Natural Language backend rejects batches over the default total-byte limit")
    func rejectsBatchOverDefaultTotalByteLimit() async throws {
        let text = String(repeating: "a", count: EmbeddingBudgetFixture.maxBytesPerText)
        let texts = Array(repeating: text, count: (EmbeddingBudgetFixture.maxTotalBytes / EmbeddingBudgetFixture.maxBytesPerText) + 1)

        await assertLimitError(
            expectedSnippet: "total batch byte limit"
        ) {
            _ = try await service.generateEmbeddings(for: texts)
        }
    }

    private func assertLimitError(
        expectedSnippet: String,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected an EmbeddingError mentioning \(expectedSnippet).")
        } catch let error as EmbeddingError {
            #expect(error.userFriendlyMessage.contains(expectedSnippet))
        } catch {
            Issue.record("Expected EmbeddingError, got \(error).")
        }
    }
}

private enum EmbeddingBudgetFixture {
    static let maxTextCount = 64
    static let maxBytesPerText = 65_536
    static let maxTotalBytes = 262_144
}
#endif
