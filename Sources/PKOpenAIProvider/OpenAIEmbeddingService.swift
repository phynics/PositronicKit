import Foundation
import Logging
import OpenAI
import PKShared
import PositronicKit

public actor OpenAIEmbeddingService: EmbeddingServiceProtocol {
    private let client: OpenAI
    private let logger = Logger.module(named: "OpenAIEmbeddingService")
    private let model: Model = "text-embedding-ada-002"

    public init(apiKey: String) {
        self.client = OpenAI(apiToken: apiKey)
    }

    public func generateEmbedding(for text: String) async throws -> [Float] {
        let query = EmbeddingsQuery(input: .string(text), model: model)

        do {
            let result = try await client.embeddings(query: query)
            guard let embedding = result.data.first?.embedding else {
                throw EmbeddingError.generationFailed
            }
            return embedding.map { Float($0) }
        } catch {
            logger.error("Failed to generate embedding: \(error)")
            throw error
        }
    }

    public func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        let query = EmbeddingsQuery(input: .stringList(texts), model: model)

        do {
            let result = try await client.embeddings(query: query)
            return result.data.sorted { $0.index < $1.index }.map { $0.embedding.map { Float($0) } }
        } catch {
            logger.error("Failed to generate embeddings: \(error)")
            throw error
        }
    }
}
