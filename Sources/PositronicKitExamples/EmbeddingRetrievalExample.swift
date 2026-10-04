import Foundation
import PKContracts
import PositronicKit

/// Example host-owned semantic retrieval.
///
/// PositronicKit deliberately ships no automatic retrieval stage. This source shows the
/// documented integration path: a host embeds the admitted Turn input with an
/// ``EmbeddingClientProtocol``, ranks a host-owned list of pre-computed embeddings with
/// ``Embedding/cosineSimilarity(to:)``, and contributes the top results as bounded Turn context.
///
/// The runtime gains no embedding API. Storage, indexing, and ranking stay in the host.
public struct EmbeddingRetrievalContextSource: TurnContextSource {
    /// One host-owned note and its pre-computed embedding.
    public struct Note: Sendable, Equatable {
        public let id: UUID
        public let content: String
        public let embedding: Embedding

        public init(id: UUID = UUID(), content: String, embedding: Embedding) {
            self.id = id
            self.content = content
            self.embedding = embedding
        }
    }

    private let client: any EmbeddingClientProtocol
    private let notes: [Note]
    private let topK: Int
    private let namespace: String

    /// Creates a retrieval source.
    ///
    /// - Parameters:
    ///   - client: The embedding client used to embed the Turn input.
    ///   - notes: The host-owned notes to rank.
    ///   - topK: The maximum number of memories to contribute.
    ///   - namespace: The contribution namespace. Must not collide with a runtime namespace.
    public init(
        client: any EmbeddingClientProtocol,
        notes: [Note],
        topK: Int = 3,
        namespace: String = "retrieval"
    ) {
        self.client = client
        self.notes = notes
        self.topK = max(0, topK)
        self.namespace = namespace
    }

    public func contributions(for request: TurnContextRequest) async throws -> [TurnContextContribution] {
        try await rankedMemories(for: request.message).map { memory in
            try TurnContextContribution(
                namespace: namespace,
                key: memory.id.uuidString,
                text: memory.content,
                requirement: .optional,
                id: memory.id
            )
        }
    }

    /// Ranks the host-owned notes against `query` and returns the top results.
    ///
    /// This is the reusable ranking step. Hosts that store embeddings in a database replace it
    /// with their own query and feed the result into an `AgentContextSource`.
    public func rankedMemories(for query: String) async throws -> [AgentContextMemory] {
        guard !notes.isEmpty else { return [] }
        let queryEmbedding = try await client.embedQuery(query)

        let ranked = try notes.map { note -> (score: Float, memory: AgentContextMemory) in
            let score = try queryEmbedding.cosineSimilarity(to: note.embedding)
            return (
                score,
                AgentContextMemory(
                    id: note.id,
                    content: note.content,
                    source: namespace,
                    relevance: Double(score)
                )
            )
        }
        .sorted { $0.score > $1.score }

        return ranked.prefix(topK).map(\.memory)
    }
}
