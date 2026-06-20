import Foundation
import PositronicKit

package enum LocalEmbeddingBackendKind: String, Sendable {
    case naturalLanguage
    case miniLM
}

package enum LocalEmbeddingBackend: Sendable {
    case naturalLanguage
    case miniLM(MiniLMEmbeddingBackend)

    package var kind: LocalEmbeddingBackendKind {
        switch self {
        case .naturalLanguage:
            return .naturalLanguage
        case .miniLM:
            return .miniLM
        }
    }

    package func generateEmbedding(for text: String) async throws -> [Float] {
        switch self {
        case .naturalLanguage:
            #if canImport(NaturalLanguage)
            return try await NaturalLanguageEmbeddingBackend().generateEmbedding(for: text)
            #else
            throw EmbeddingError.modelUnavailable
            #endif
        case let .miniLM(backend):
            return try await backend.generateEmbedding(for: text)
        }
    }

    package func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        switch self {
        case .naturalLanguage:
            #if canImport(NaturalLanguage)
            return try await NaturalLanguageEmbeddingBackend().generateEmbeddings(for: texts)
            #else
            throw EmbeddingError.modelUnavailable
            #endif
        case let .miniLM(backend):
            return try await backend.generateEmbeddings(for: texts)
        }
    }
}
