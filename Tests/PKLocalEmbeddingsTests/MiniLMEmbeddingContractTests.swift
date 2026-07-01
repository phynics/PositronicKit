import Foundation
@testable import PKLocalEmbeddings
import PKShared
import PositronicKit
import XCTest

#if os(Linux) || MiniLMEmbeddings
final class MiniLMEmbeddingContractTests: XCTestCase {
    private func makeService() throws -> LocalEmbeddingService {
        let modelDirectory = try MiniLMTestSupport.requireModelDirectory()
        #if os(Linux)
        return try LocalEmbeddingService(modelDirectory: modelDirectory)
        #else
        return try LocalEmbeddingService(miniLMModelDirectory: modelDirectory)
        #endif
    }

    private func makeService(inputBudget: EmbeddingInputBudget) throws -> LocalEmbeddingService {
        let modelDirectory = try MiniLMTestSupport.requireModelDirectory()
        #if os(Linux)
        return try LocalEmbeddingService(modelDirectory: modelDirectory, inputBudget: inputBudget)
        #else
        return try LocalEmbeddingService(miniLMModelDirectory: modelDirectory, inputBudget: inputBudget)
        #endif
    }

    func testConstructsAndEmbedsNormalized384Vector() async throws {
        let service = try makeService()
        let vector = try await service.generateEmbedding(for: "The cat sits on the mat.")

        XCTAssertEqual(service.backendIdentifier, .miniLM)
        XCTAssertEqual(vector.count, 384)
        XCTAssertEqual(MiniLMTestSupport.l2Norm(vector), 1, accuracy: 0.00001)
    }

    func testMatchesPKFastEmbedGoldenVector() async throws {
        let service = try makeService()
        let vector = try await service.generateEmbedding(for: "The cat sits on the mat.")
        let expected = try MiniLMTestSupport.goldenVectorPrefix()

        XCTAssertGreaterThanOrEqual(vector.count, expected.count)
        for (actual, golden) in zip(vector, expected) {
            XCTAssertEqual(actual, golden, accuracy: 0.00001)
        }
    }

    func testDeterministicForRepeatedInput() async throws {
        let service = try makeService()
        let first = try await service.generateEmbedding(for: "A deterministic fixture sentence.")
        let second = try await service.generateEmbedding(for: "A deterministic fixture sentence.")

        XCTAssertEqual(first.count, second.count)
        for (lhs, rhs) in zip(first, second) {
            XCTAssertEqual(lhs, rhs, accuracy: 0.00001)
        }
    }

    func testBatchMatchesSingleEmbeddings() async throws {
        let service = try makeService()
        let texts = ["alpha", "beta", "gamma"]

        let batch = try await service.generateEmbeddings(for: texts)
        let singles = try await texts.asyncMap { try await service.generateEmbedding(for: $0) }

        XCTAssertEqual(batch.count, singles.count)
        for (lhs, rhs) in zip(batch, singles) {
            XCTAssertEqual(lhs.count, rhs.count)
            for (left, right) in zip(lhs, rhs) {
                XCTAssertEqual(left, right, accuracy: 0.00001)
            }
        }
    }

    func testEmptyBatchReturnsEmptyResult() async throws {
        let service = try makeService()
        let vectors = try await service.generateEmbeddings(for: [])
        XCTAssertEqual(vectors, [])
    }

    func testRejectsTextOverDefaultByteLimit() async throws {
        let service = try makeService()
        let text = String(repeating: "a", count: EmbeddingBudgetFixture.maxBytesPerText + 1)

        try await assertLimitError(
            expectedSnippet: "per-text byte limit"
        ) {
            _ = try await service.generateEmbedding(for: text)
        }
    }

    func testRejectsBatchOverDefaultTextCountLimit() async throws {
        let service = try makeService()
        let texts = Array(repeating: "a", count: EmbeddingBudgetFixture.maxTextCount + 1)

        try await assertLimitError(
            expectedSnippet: "batch text-count limit"
        ) {
            _ = try await service.generateEmbeddings(for: texts)
        }
    }

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

    func testConfiguredBudgetPropagatesIntoMiniLMBackend() throws {
        let budget = EmbeddingInputBudget(
            maxTextCount: 3,
            maxBytesPerText: 8,
            maxTotalBytes: 16
        )
        let service = try makeService(inputBudget: budget)

        XCTAssertEqual(service.inputBudget, budget)
        XCTAssertEqual(service.backendInputBudget, budget)
    }

    func testMiniLMBackendUsesConfiguredBudgetAndPreservesTypedLimitError() async throws {
        let budget = EmbeddingInputBudget(
            maxTextCount: 3,
            maxBytesPerText: 2,
            maxTotalBytes: 16
        )
        let modelDirectory = try MiniLMTestSupport.requireModelDirectory()
        let backend = try MiniLMEmbeddingBackend(modelDirectory: modelDirectory, inputBudget: budget)

        do {
            _ = try await backend.generateEmbedding(for: "abc")
            XCTFail("Expected configured per-text budget to be enforced.")
        } catch let error as EmbeddingError {
            XCTAssertEqual(error, .perTextByteLimitExceeded(max: 2, actual: 3))
        } catch {
            XCTFail("Expected EmbeddingError, got \(error)")
        }
    }

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

        XCTAssertEqual(vectors.count, 8)
        for vector in vectors {
            XCTAssertEqual(vector, expected)
        }
    }

    func testRelatedSentencesRankAboveUnrelatedSentence() async throws {
        let service = try makeService()
        let anchor = try await service.generateEmbedding(for: "Swift concurrency uses actors for isolation.")
        let related = try await service.generateEmbedding(for: "Actors isolate mutable state in Swift.")
        let unrelated = try await service.generateEmbedding(for: "Bananas grow in tropical climates.")

        XCTAssertGreaterThan(
            MiniLMTestSupport.cosineSimilarity(anchor, related),
            MiniLMTestSupport.cosineSimilarity(anchor, unrelated)
        )
    }

    func testValidationFailuresSurfaceStableErrors() throws {
        let sourceDirectory = try MiniLMTestSupport.requireModelDirectory()

        let missingDirectory = URL(fileURLWithPath: "/definitely/missing")
        XCTAssertThrowsError(try constructService(at: missingDirectory)) { error in
            XCTAssertEqual(error as? EmbeddingError, .modelDirectoryMissing)
        }

        let missingFileDirectory = try MiniLMTestSupport.makeScratchCopy(of: sourceDirectory)
        try FileManager.default.removeItem(at: missingFileDirectory.appendingPathComponent("tokenizer.json"))
        XCTAssertThrowsError(try constructService(at: missingFileDirectory)) { error in
            XCTAssertEqual(error as? EmbeddingError, .modelFilesMissing)
        }

        let checksumDirectory = try MiniLMTestSupport.makeScratchCopy(of: sourceDirectory)
        try Data("broken".utf8).write(to: checksumDirectory.appendingPathComponent("tokenizer.json"))
        XCTAssertThrowsError(try constructService(at: checksumDirectory)) { error in
            XCTAssertEqual(error as? EmbeddingError, .modelChecksumMismatch)
        }
    }

    private func constructService(at modelDirectory: URL) throws -> LocalEmbeddingService {
        #if os(Linux)
        return try LocalEmbeddingService(modelDirectory: modelDirectory)
        #else
        return try LocalEmbeddingService(miniLMModelDirectory: modelDirectory)
        #endif
    }

    private func assertLimitError(
        expectedSnippet: String,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            XCTFail("Expected an EmbeddingError mentioning \(expectedSnippet).")
        } catch let error as EmbeddingError {
            XCTAssertTrue(
                error.userFriendlyMessage.contains(expectedSnippet),
                "Expected snippet '\(expectedSnippet)' in '\(error.userFriendlyMessage)'"
            )
        } catch {
            XCTFail("Expected EmbeddingError, got \(error)")
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
