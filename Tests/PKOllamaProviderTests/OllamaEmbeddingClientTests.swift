import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import PKContracts
import PKTestSupport
import PKUtilities
import Testing
@testable import PKOllamaProvider

@Suite("Ollama embedding client")
struct OllamaEmbeddingClientTests {
    private func makeClient(
        transport: ScriptedProviderHTTPTransport
    ) -> OllamaEmbeddingClient {
        OllamaEmbeddingClient(
            endpoint: "http://127.0.0.1:11434",
            modelName: "nomic-embed-text",
            inputBudget: .default,
            transport: transport
        )
    }

    private let responseJSON = #"""
    {
      "model": "nomic-embed-text",
      "embeddings": [[0.1, 0.2], [0.3, 0.4]],
      "prompt_eval_count": 5
    }
    """#

    @Test("Posts inputs to /api/embed and stamps an unnormalized space")
    func postsAndDecodes() async throws {
        let transport = ScriptedProviderHTTPTransport(responses: [.dataResponse(Data(responseJSON.utf8))])
        let client = makeClient(transport: transport)

        let response = try await client.embed(EmbeddingRequest(inputs: ["first", "second"], purpose: .document))

        #expect(response.embeddings.map(\.vector) == [[0.1, 0.2], [0.3, 0.4]])
        #expect(response.embeddings.allSatisfy { $0.space.provider == "ollama" })
        #expect(response.embeddings.allSatisfy { $0.space.model == "nomic-embed-text" })
        #expect(response.embeddings.allSatisfy { $0.space.dimensions == 2 })
        #expect(response.embeddings.allSatisfy { !$0.space.isNormalized })
        #expect(response.usage?.inputTokens == 5)

        let request = try #require(await transport.lastRequest())
        #expect(request.url?.path == "/api/embed")
        #expect(request.httpMethod == "POST")

        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "nomic-embed-text")
        #expect((object["input"] as? [String]) == ["first", "second"])
    }

    @Test("A response with the wrong number of embeddings throws responseCountMismatch")
    func countMismatchThrows() async {
        let transport = ScriptedProviderHTTPTransport(responses: [
            .dataResponse(Data(#"{"embeddings":[[1.0,0.0]]}"#.utf8)),
        ])
        let client = makeClient(transport: transport)

        await #expect(throws: EmbeddingError.responseCountMismatch(expected: 2, actual: 1)) {
            _ = try await client.embed(EmbeddingRequest(inputs: ["a", "b"], purpose: .query))
        }
    }

    @Test("Conformance suite accepts an Ollama client")
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
