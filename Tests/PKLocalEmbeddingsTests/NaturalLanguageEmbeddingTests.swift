import Foundation
@testable import PKLocalEmbeddings
import PKShared
import PKUtilities
import PositronicKit
import Testing

#if canImport(NaturalLanguage)
    import NaturalLanguage

    /// NLEmbedding relies on on-device model assets that may not be provisioned on a fresh host
    /// (e.g. a CI runner that hasn't downloaded Apple's NL data). Skip rather than fail in that case.
    private let naturalLanguageAssetsAvailable = NLEmbedding.sentenceEmbedding(for: .english) != nil

    @Suite("Natural Language embeddings", .disabled(if: !naturalLanguageAssetsAvailable, "NLEmbedding assets not available on this host"))
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
        func rejectsTextOverDefaultByteLimit() async {
            let text = String(repeating: "a", count: EmbeddingBudgetFixture.maxBytesPerText + 1)

            await assertLimitError(
                expectedSnippet: "per-text byte limit"
            ) {
                _ = try await service.generateEmbedding(for: text)
            }
        }

        @Test("Natural Language backend rejects a single text over a custom total-byte limit")
        func rejectsSingleTextOverCustomTotalByteLimit() async {
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
        func rejectsBatchOverDefaultTextCountLimit() async {
            let texts = Array(repeating: "a", count: EmbeddingBudgetFixture.maxTextCount + 1)

            await assertLimitError(
                expectedSnippet: "batch text-count limit"
            ) {
                _ = try await service.generateEmbeddings(for: texts)
            }
        }

        @Test("Batch embeddings match repeated single embeddings for the Apple backend")
        func batchMatchesSingleEmbeddings() async throws {
            let texts = ["Swift concurrency uses actors.", "Bananas grow in tropical climates.", "A stable fixture sentence."]

            let batch = try await service.generateEmbeddings(for: texts)
            var singles: [[Float]] = []
            for text in texts {
                try singles.append(await service.generateEmbedding(for: text))
            }

            #expect(batch.count == singles.count)
            for (lhs, rhs) in zip(batch, singles) {
                #expect(lhs.count == rhs.count)
                #expect(zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.000_001 })
            }
        }

        @Test("Natural Language backend rejects batches over the default total-byte limit")
        func rejectsBatchOverDefaultTotalByteLimit() async {
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
        static let maxBytesPerText = 65536
        static let maxTotalBytes = 262_144
    }
#endif
