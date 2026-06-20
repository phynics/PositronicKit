import Foundation
@testable import PKLocalEmbeddings
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
}
#endif
