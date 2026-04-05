import MonadShared
import Foundation

/// Protocol for a service that can generate vector embeddings for text
public protocol EmbeddingService: Sendable {
    /// Generate embedding vector for a single string
    /// - Parameter text: The text to vectorize
    /// - Returns: An array of Doubles representing the vector
    func generateEmbedding(for text: String) async throws -> [Double]

    /// Generate embeddings for multiple strings
    func generateEmbeddings(for texts: [String]) async throws -> [[Double]]
}
