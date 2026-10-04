import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import PKContracts
import PKTestSupport
import PKUtilities
import Testing
@testable import PKOpenAIProvider

@Suite("OpenAI embedding client")
struct OpenAIEmbeddingClientTests {
    private func makeClient(
        transport: ScriptedProviderHTTPTransport
    ) -> OpenAIEmbeddingClient {
        OpenAIEmbeddingClient(
            apiKey: "secret-key",
            modelName: "text-embedding-3-small",
            host: "127.0.0.1",
            port: 8080,
            scheme: "http",
            inputBudget: .default,
            transport: transport
        )
    }

    private let responseJSON = #"""
    {
      "object": "list",
      "data": [
        {"object": "embedding", "index": 1, "embedding": [0.3, 0.4]},
        {"object": "embedding", "index": 0, "embedding": [0.1, 0.2]}
      ],
      "model": "text-embedding-3-small",
      "usage": {"prompt_tokens": 8, "total_tokens": 8}
    }
    """#

    @Test("Posts inputs to /v1/embeddings and returns index-sorted embeddings")
    func postsAndDecodes() async throws {
        let transport = ScriptedProviderHTTPTransport(responses: [.dataResponse(Data(responseJSON.utf8))])
        let client = makeClient(transport: transport)

        let response = try await client.embed(EmbeddingRequest(
            inputs: ["first", "second"],
            purpose: .document,
            dimensions: 256
        ))

        #expect(response.embeddings.map(\.vector) == [[0.1, 0.2], [0.3, 0.4]])
        #expect(response.embeddings.allSatisfy { $0.space.provider == "openai" })
        #expect(response.embeddings.allSatisfy { $0.space.model == "text-embedding-3-small" })
        #expect(response.embeddings.allSatisfy { $0.space.dimensions == 2 })
        #expect(response.embeddings.allSatisfy { $0.space.isNormalized })
        #expect(response.usage?.inputTokens == 8)

        let request = try #require(await transport.lastRequest())
        #expect(request.url?.path == "/v1/embeddings")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "text-embedding-3-small")
        #expect(object["dimensions"] as? Int == 256)
        #expect(object["encoding_format"] as? String == "float")
        #expect((object["input"] as? [String]) == ["first", "second"])
    }

    @Test("A response with the wrong number of embeddings throws responseCountMismatch")
    func countMismatchThrows() async {
        let transport = ScriptedProviderHTTPTransport(responses: [
            .dataResponse(Data(#"{"data":[{"index":0,"embedding":[1.0,0.0]}],"usage":null}"#.utf8)),
        ])
        let client = makeClient(transport: transport)

        await #expect(throws: EmbeddingError.responseCountMismatch(expected: 2, actual: 1)) {
            _ = try await client.embed(EmbeddingRequest(inputs: ["a", "b"], purpose: .query))
        }
    }

    @Test("Budget violations are rejected before any transport call")
    func budgetRejectedBeforeTransport() async {
        let transport = ScriptedProviderHTTPTransport()
        let client = makeClient(transport: transport)
        let budget = client.inputBudget
        let oversized = String(repeating: "a", count: budget.maxBytesPerText + 1)

        await #expect(throws: EmbeddingError.perTextByteLimitExceeded(
            max: budget.maxBytesPerText,
            actual: budget.maxBytesPerText + 1
        )) {
            _ = try await client.embed(EmbeddingRequest(inputs: [oversized], purpose: .document))
        }
        #expect(await transport.requestCount() == 0)
    }

    @Test("Conformance suite accepts an OpenAI client")
    func conformance() async throws {
        let transport = ScriptedProviderHTTPTransport(responses: [.dataResponse(Data(responseJSON.utf8))])
        let client = makeClient(transport: transport)

        try await EmbeddingClientConformanceSuite.run(
            client: client,
            inputs: ["first", "second"],
            expectedVectors: [[0.1, 0.2], [0.3, 0.4]]
        )
    }
}
