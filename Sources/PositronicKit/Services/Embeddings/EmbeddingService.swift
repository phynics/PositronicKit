import PKShared
import Foundation

@available(*, deprecated, message: "Use EmbeddingServiceProtocol. This older protocol duplicates the embedding API with a different vector element type.")
/// Legacy embedding protocol kept for source compatibility.
public protocol EmbeddingService: Sendable {
    /// Generate embedding vector for a single string
    /// - Parameter text: The text to vectorize
    /// - Returns: An array of Doubles representing the vector
    func generateEmbedding(for text: String) async throws -> [Double]

    /// Generate embeddings for multiple strings
    func generateEmbeddings(for texts: [String]) async throws -> [[Double]]
}
