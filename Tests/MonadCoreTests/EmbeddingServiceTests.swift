import Foundation
import MonadCore
import Testing

@Suite struct EmbeddingServiceTests {
    private let service = LocalEmbeddingService()

    @Test("Test generating a single embedding")
    func generateSingle() async throws {
        let vector = try await service.generateEmbedding(for: "Hello world")

        #expect(!vector.isEmpty)
        #expect(vector.count > 0)

        // NaturalLanguage sentence embeddings are typically 512 dimensions
        #expect(vector.count == 512)
    }

    @Test("Test generating multiple embeddings")
    func generateMultiple() async throws {
        let texts = ["Apple", "Banana", "Orange"]
        let vectors = try await service.generateEmbeddings(for: texts)

        #expect(vectors.count == 3)
        #expect(vectors[0].count == 512)
    }

    @Test("Test semantic similarity logic")
    func semanticSimilarity() async throws {
        let v1 = try await service.generateEmbedding(for: "I love programming in Swift")
        let v2 = try await service.generateEmbedding(for: "Coding in Apple's language is fun")
        let v3 = try await service.generateEmbedding(for: "The weather is nice today")

        let sim12 = cosineSimilarity(v1, v2)
        let sim13 = cosineSimilarity(v1, v3)

        // v1 and v2 should be more similar than v1 and v3
        #expect(sim12 > sim13)
        #expect(sim12 > 0.4) // NaturalLanguage embeddings can be quite sparse
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        var dotProduct: Float = 0.0
        var magA: Float = 0.0
        var magB: Float = 0.0
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        return dotProduct / (sqrt(magA) * sqrt(magB))
    }
}
