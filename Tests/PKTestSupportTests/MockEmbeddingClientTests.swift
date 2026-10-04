import Foundation
import PKContracts
import PKTestSupport
import Testing

@Suite("MockEmbeddingClient")
struct MockEmbeddingClientTests {
    @Test("Produces one deterministic embedding per input")
    func deterministicVectors() async throws {
        let client = MockEmbeddingClient()

        let first = try await client.embedDocuments(["alpha", "beta"])
        let second = try await client.embedDocuments(["alpha", "beta"])

        #expect(first == second)
        #expect(first[0].vector != first[1].vector)
        #expect(first.allSatisfy { $0.space == client.space })
    }

    @Test("Records admitted requests and reports usage")
    func recordsRequests() async throws {
        let client = MockEmbeddingClient()
        let response = try await client.embed(EmbeddingRequest(inputs: ["alpha", "beta"], purpose: .query))

        #expect(client.recordedRequests.count == 1)
        #expect(client.recordedRequests[0].purpose == .query)
        #expect(response.embeddings.count == 2)
        #expect(response.usage != nil)
    }

    @Test("Does not record a request that violates the budget")
    func doesNotRecordRejectedRequest() async {
        let budget = EmbeddingInputBudget(maxTextCount: 1, maxBytesPerText: 2, maxTotalBytes: 100)
        let client = MockEmbeddingClient(inputBudget: budget)

        await #expect(throws: EmbeddingError.perTextByteLimitExceeded(max: 2, actual: 3)) {
            _ = try await client.embed(EmbeddingRequest(inputs: ["abc"], purpose: .query))
        }
        #expect(client.recordedRequests.isEmpty)
    }

    @Test("Throws a scripted error after recording")
    func throwsScriptedError() async {
        let client = MockEmbeddingClient()
        client.errorToThrow = .modelUnavailable

        await #expect(throws: EmbeddingError.modelUnavailable) {
            _ = try await client.embed(EmbeddingRequest(inputs: ["alpha"], purpose: .query))
        }
        #expect(client.recordedRequests.count == 1)
    }
}
