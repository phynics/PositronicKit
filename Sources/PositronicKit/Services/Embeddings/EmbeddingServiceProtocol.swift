import PKShared
import PKUtilities
import Foundation

public protocol EmbeddingServiceProtocol: Sendable {
    func generateEmbedding(for text: String) async throws -> [Float]
    func generateEmbeddings(for texts: [String]) async throws -> [[Float]]
}
