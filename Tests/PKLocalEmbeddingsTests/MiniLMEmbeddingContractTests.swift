import Foundation
@testable import PKLocalEmbeddings
import PKContracts
import PKUtilities
import PositronicKit
import Testing

#if os(Linux) || MiniLMEmbeddings
@Suite("MiniLM embedding contract")
struct MiniLMEmbeddingContractTests {
    private func makeService() throws -> LocalEmbeddingService {
        let modelDirectory = try MiniLMTestSupport.requireModelDirectory()
        return try LocalEmbeddingService(miniLMModelDirectory: modelDirectory)
    }

    private func makeService(inputBudget: EmbeddingInputBudget) throws -> LocalEmbeddingService {
        let modelDirectory = try MiniLMTestSupport.requireModelDirectory()
        return try LocalEmbeddingService(miniLMModelDirectory: modelDirectory, inputBudget: inputBudget)
    }

    @Test("Constructs a normalized 384-element vector")
    func testConstructsAndEmbedsNormalized384Vector() async throws {
        let service = try makeService()
        let vector = try await service.generateEmbedding(for: "The cat sits on the mat.")

        #expect(service.backendIdentifier == .miniLM)
        #expect(vector.count == 384)
        #expect(abs(MiniLMTestSupport.l2Norm(vector) - 1) < 0.00001)
    }

    @Test("Matches the PKFastEmbed golden vector")
    func testMatchesPKFastEmbedGoldenVector() async throws {
        let service = try makeService()
        let vector = try await service.generateEmbedding(for: "The cat sits on the mat.")
        let expected = try MiniLMTestSupport.goldenVectorPrefix()

        #expect(vector.count >= expected.count)
        for (actual, golden) in zip(vector, expected) {
            #expect(abs(actual - golden) < 0.00001)
        }
    }

    @Test("Repeated input is deterministic")
    func testDeterministicForRepeatedInput() async throws {
        let service = try makeService()
        let first = try await service.generateEmbedding(for: "A deterministic fixture sentence.")
        let second = try await service.generateEmbedding(for: "A deterministic fixture sentence.")

        #expect(first.count == second.count)
        for (lhs, rhs) in zip(first, second) {
            #expect(abs(lhs - rhs) < 0.00001)
        }
    }

    @Test("Batch embeddings match single embeddings")
    func testBatchMatchesSingleEmbeddings() async throws {
        let service = try makeService()
        let texts = ["alpha", "beta", "gamma"]

        let batch = try await service.generateEmbeddings(for: texts)
        let singles = try await texts.asyncMap { try await service.generateEmbedding(for: $0) }

        #expect(batch.count == singles.count)
        for (lhs, rhs) in zip(batch, singles) {
            #expect(lhs.count == rhs.count)
            for (left, right) in zip(lhs, rhs) {
                #expect(abs(left - right) < 0.00001)
            }
        }
    }

    @Test("Empty batch returns an empty result")
    func testEmptyBatchReturnsEmptyResult() async throws {
        let service = try makeService()
        let vectors = try await service.generateEmbeddings(for: [])
        #expect(vectors.isEmpty)
    }

    @Test("Rejects text over the default byte limit")
    func testRejectsTextOverDefaultByteLimit() async throws {
        let service = try makeService()
        let text = String(repeating: "a", count: EmbeddingBudgetFixture.maxBytesPerText + 1)

        try await assertLimitError(
            expectedSnippet: "per-text byte limit"
        ) {
            _ = try await service.generateEmbedding(for: text)
        }
    }

    @Test("Rejects a batch over the default text count limit")
    func testRejectsBatchOverDefaultTextCountLimit() async throws {
        let service = try makeService()
        let texts = Array(repeating: "a", count: EmbeddingBudgetFixture.maxTextCount + 1)

        try await assertLimitError(
            expectedSnippet: "batch text-count limit"
        ) {
            _ = try await service.generateEmbeddings(for: texts)
        }
    }

    @Test("Rejects a batch over the default total byte limit")
    func testRejectsBatchOverDefaultTotalByteLimit() async throws {
        let service = try makeService()
        let text = String(repeating: "a", count: EmbeddingBudgetFixture.maxBytesPerText)
        let texts = Array(repeating: text, count: (EmbeddingBudgetFixture.maxTotalBytes / EmbeddingBudgetFixture.maxBytesPerText) + 1)

        try await assertLimitError(
            expectedSnippet: "total batch byte limit"
        ) {
            _ = try await service.generateEmbeddings(for: texts)
        }
    }

    @Test("Configured budget propagates into the MiniLM backend")
    func testConfiguredBudgetPropagatesIntoMiniLMBackend() throws {
        let budget = EmbeddingInputBudget(
            maxTextCount: 3,
            maxBytesPerText: 8,
            maxTotalBytes: 16
        )
        let service = try makeService(inputBudget: budget)

        #expect(service.inputBudget == budget)
        #expect(service.backendInputBudget == budget)
    }

    @Test("Configured budget preserves typed limit errors")
    func testMiniLMBackendUsesConfiguredBudgetAndPreservesTypedLimitError() async throws {
        let budget = EmbeddingInputBudget(
            maxTextCount: 3,
            maxBytesPerText: 2,
            maxTotalBytes: 16
        )
        let service = try makeService(inputBudget: budget)

        do {
            _ = try await service.generateEmbedding(for: "abc")
            Issue.record("Expected configured per-text budget to be enforced.")
        } catch let error as EmbeddingError {
            #expect(error == .perTextByteLimitExceeded(max: 2, actual: 3))
        } catch {
            Issue.record("Expected EmbeddingError, got \(error)")
        }
    }

    @Test("Concurrent calls are serialized safely")
    func testConcurrentCallsAreSerializedSafely() async throws {
        let service = try makeService()
        let expected = try await service.generateEmbedding(for: "Concurrent embedding fixture.")

        let vectors = try await withThrowingTaskGroup(of: [Float].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await service.generateEmbedding(for: "Concurrent embedding fixture.")
                }
            }

            var results: [[Float]] = []
            for try await vector in group {
                results.append(vector)
            }
            return results
        }

        #expect(vectors.count == 8)
        for vector in vectors {
            #expect(vector == expected)
        }
    }

    @Test("Related sentences rank above an unrelated sentence")
    func testRelatedSentencesRankAboveUnrelatedSentence() async throws {
        let service = try makeService()
        let anchor = try await service.generateEmbedding(for: "Swift concurrency uses actors for isolation.")
        let related = try await service.generateEmbedding(for: "Actors isolate mutable state in Swift.")
        let unrelated = try await service.generateEmbedding(for: "Bananas grow in tropical climates.")

        #expect(
            MiniLMTestSupport.cosineSimilarity(anchor, related)
                > MiniLMTestSupport.cosineSimilarity(anchor, unrelated)
        )
    }

    @Test("Validation failures surface stable errors")
    func testValidationFailuresSurfaceStableErrors() throws {
        let sourceDirectory = try MiniLMTestSupport.requireModelDirectory()

        let missingDirectory = URL(fileURLWithPath: "/definitely/missing")
        #expect(throws: EmbeddingError.modelDirectoryMissing) {
            try constructService(at: missingDirectory)
        }

        let missingFileDirectory = try MiniLMTestSupport.makeScratchCopy(of: sourceDirectory)
        try FileManager.default.removeItem(at: missingFileDirectory.appendingPathComponent("tokenizer.json"))
        #expect(throws: EmbeddingError.modelFilesMissing) {
            try constructService(at: missingFileDirectory)
        }

        let checksumDirectory = try MiniLMTestSupport.makeScratchCopy(of: sourceDirectory)
        try Data("broken".utf8).write(to: checksumDirectory.appendingPathComponent("tokenizer.json"))
        #expect(throws: EmbeddingError.modelChecksumMismatch) {
            try constructService(at: checksumDirectory)
        }
    }

    private func constructService(at modelDirectory: URL) throws -> LocalEmbeddingService {
        return try LocalEmbeddingService(miniLMModelDirectory: modelDirectory)
    }

    private func assertLimitError(
        expectedSnippet: String,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            Issue.record("Expected an EmbeddingError mentioning \(expectedSnippet).")
        } catch let error as EmbeddingError {
            #expect(error.userFriendlyMessage.contains(expectedSnippet))
        } catch {
            Issue.record("Expected EmbeddingError, got \(error)")
        }
    }
}

private extension Array where Element == String {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for value in self {
            results.append(try await transform(value))
        }
        return results
    }
}

private enum EmbeddingBudgetFixture {
    static let maxTextCount = 64
    static let maxBytesPerText = 65_536
    static let maxTotalBytes = 262_144
}
#endif
