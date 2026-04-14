import ErrorKit
import PKShared
import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Embedding service using Apple's NaturalLanguage framework
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

public enum EmbeddingError: MonadError {
    case modelUnavailable
    case generationFailed
    case platformNotSupported

    public var errorDomain: String { MonadErrorDomain.embedding }

    public var errorCode: Int {
        switch self {
        case .modelUnavailable: return 8001
        case .generationFailed: return 8002
        case .platformNotSupported: return 8003
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .modelUnavailable:
            return "Local embedding capabilities are not available on this device."
        case .generationFailed:
            return "Failed to process the text for embedding. Please try again."
        case .platformNotSupported:
            return "Local text analysis is only supported on Apple devices."
        }
    }
}
