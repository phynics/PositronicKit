import Foundation
import PKContracts

/// Returns empty embeddings. Suitable when embedding-based search is not needed.
public struct NoOpEmbeddingService: EmbeddingServiceProtocol, Sendable {
    public init() {}

    public func generateEmbedding(for _: String) async throws -> [Float] {
        []
    }

    public func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [] }
    }
}
