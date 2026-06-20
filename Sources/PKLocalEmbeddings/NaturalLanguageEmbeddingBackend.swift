import Foundation
import PositronicKit

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

package struct NaturalLanguageEmbeddingBackend: Sendable {
    package init() {}

    package func generateEmbedding(for text: String) async throws -> [Float] {
        #if canImport(NaturalLanguage)
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbeddingError.modelUnavailable
        }

        guard let vector = embedding.vector(for: text) else {
            throw EmbeddingError.generationFailed
        }

        return vector.map { Float($0) }
        #else
        _ = text
        throw EmbeddingError.modelUnavailable
        #endif
    }

    package func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)

        for text in texts {
            results.append(try await generateEmbedding(for: text))
        }

        return results
    }
}
