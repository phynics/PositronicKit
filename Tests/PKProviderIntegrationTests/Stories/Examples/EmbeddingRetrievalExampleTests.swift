import Foundation
import PKContracts
import PKTestSupport
import PositronicKit
import PositronicKitExamples
import Testing

@Suite("Embedding retrieval example")
struct EmbeddingRetrievalExampleTests {
    private func makeRequest(message: String) -> TurnContextRequest {
        TurnContextRequest(
            timelineID: UUID(),
            turnID: UUID(),
            requestID: UUID(),
            agentID: nil,
            executionKind: .direct,
            message: message
        )
    }

    @Test("Ranked memories are ordered by cosine similarity and bounded by topK")
    func ranksAndBounds() async throws {
        let client = MockEmbeddingClient()
        let query = "swift concurrency"
        let queryEmbedding = try await client.embedQuery(query)

        // A note identical to the query must outrank an unrelated note.
        let identical = EmbeddingRetrievalContextSource.Note(
            content: "swift concurrency",
            embedding: queryEmbedding
        )
        let orthogonal = EmbeddingRetrievalContextSource.Note(
            content: "gardening",
            embedding: Embedding(
                vector: queryEmbedding.vector.map { _ in 0 },
                space: queryEmbedding.space
            )
        )

        let source = EmbeddingRetrievalContextSource(
            client: client,
            notes: [orthogonal, identical],
            topK: 1
        )

        let memories = try await source.rankedMemories(for: query)
        #expect(memories.map(\.id) == [identical.id])
        #expect((memories[0].relevance ?? 0) > 0.99)
        #expect(memories[0].source == "retrieval")
    }

    @Test("Contributions carry the ranked memories under the configured namespace")
    func contributionsUseNamespace() async throws {
        let client = MockEmbeddingClient()
        let note = EmbeddingRetrievalContextSource.Note(
            content: "remember this",
            embedding: try await client.embedQuery("hello")
        )
        let source = EmbeddingRetrievalContextSource(client: client, notes: [note], topK: 3)

        let contributions = try await source.contributions(for: makeRequest(message: "hello"))

        #expect(contributions.count == 1)
        #expect(contributions[0].namespace == "retrieval")
        #expect(contributions[0].key == note.id.uuidString)
        #expect(contributions[0].value.textValue == "remember this")
    }

    @Test("An empty note list returns no memories and records no embedding request")
    func emptyNotesSkipEmbedding() async throws {
        let client = MockEmbeddingClient()
        let source = EmbeddingRetrievalContextSource(client: client, notes: [], topK: 3)

        let memories = try await source.rankedMemories(for: "anything")

        #expect(memories.isEmpty)
        #expect(client.recordedRequests.isEmpty)
    }
}
