import Foundation
import PKContracts
import PKTestSupport
import Testing

@Suite("EmbeddingClientProtocol extension")
struct EmbeddingClientProtocolTests {
    @Test("embedQuery preserves purpose and returns one embedding")
    func embedQueryReturnsOne() async throws {
        let client = MockEmbeddingClient()
        let embedding = try await client.embedQuery("hello")
        #expect(embedding.vector.count == client.space.dimensions)
        #expect(client.recordedRequests.map(\.purpose) == [.query])
    }

    @Test("embedDocuments splits input into budget-sized document batches")
    func embedDocumentsBatches() async throws {
        let budget = EmbeddingInputBudget(maxTextCount: 2, maxBytesPerText: 100, maxTotalBytes: 1000)
        let client = MockEmbeddingClient(inputBudget: budget)

        let embeddings = try await client.embedDocuments(["a", "b", "c", "d", "e"])

        #expect(embeddings.count == 5)
        #expect(client.recordedRequests.count == 3)
        #expect(client.recordedRequests.map(\.inputs.count) == [2, 2, 1])
        #expect(client.recordedRequests.allSatisfy { $0.purpose == .document })
    }

    @Test("A short provider response surfaces responseCountMismatch")
    func shortResponseThrows() async throws {
        let client = MockEmbeddingClient()
        client.responseCountOverride = 0

        await #expect(throws: EmbeddingError.responseCountMismatch(expected: 1, actual: 0)) {
            try await client.embedQuery("hello")
        }
    }

    @Test("A budget violation is thrown before the request is recorded")
    func budgetViolationBeforeIO() async {
        let budget = EmbeddingInputBudget(maxTextCount: 1, maxBytesPerText: 2, maxTotalBytes: 10)
        let client = MockEmbeddingClient(inputBudget: budget)

        await #expect(throws: EmbeddingError.perTextByteLimitExceeded(max: 2, actual: 3)) {
            _ = try await client.embed(EmbeddingRequest(inputs: ["abc"], purpose: .query))
        }
        #expect(client.recordedRequests.isEmpty)
    }
}
