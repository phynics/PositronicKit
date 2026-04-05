import MonadShared
import Foundation
import OpenAI
import Logging

public actor OpenAIEmbeddingService: EmbeddingServiceProtocol {
    private let client: OpenAI
    private let logger = Logger.module(named: "OpenAIEmbeddingService")
    // Model is typealias for String in OpenAI library
    private let model: Model = "text-embedding-ada-002"

    public init(apiKey: String) {
        self.client = OpenAI(apiToken: apiKey)
    }

    public func generateEmbedding(for text: String) async throws -> [Float] {
        let query = EmbeddingsQuery(
            input: .string(text),
            model: model
        )

        do {
            let result = try await client.embeddings(query: query)
            guard let embedding = result.data.first?.embedding else {
                throw EmbeddingError.generationFailed
            }
            // OpenAI returns [Double], convert to [Float]
            return embedding.map { Float($0) }
        } catch {
            logger.error("Failed to generate embedding: \(error)")
            throw error
        }
    }

    public func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        let query = EmbeddingsQuery(
            input: .stringList(texts),
            model: model
        )

        do {
            let result = try await client.embeddings(query: query)
            // Ensure order is preserved. Result data has 'index'.
            let sortedData = result.data.sorted { $0.index < $1.index }
            return sortedData.map { $0.embedding.map { Float($0) } }
        } catch {
            logger.error("Failed to generate embeddings: \(error)")
            throw error
        }
    }
}
