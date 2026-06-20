import Foundation
import PositronicKit
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Embedding service using the platform-local default implementation.
public final class LocalEmbeddingService: EmbeddingServiceProtocol {
    public init() {}

    public func generateEmbedding(for text: String) async throws -> [Float] {
        #if canImport(NaturalLanguage)
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbeddingError.modelUnavailable
        }

        guard let vector = embedding.vector(for: text) else {
            throw EmbeddingError.generationFailed
        }

        return vector.map { Float($0) }
        #else
        throw EmbeddingError.platformNotSupported
        #endif
    }

    public func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        for text in texts {
            results.append(try await generateEmbedding(for: text))
        }
        return results
    }
}
