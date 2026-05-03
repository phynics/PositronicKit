import PKTestSupport
import Testing
@testable import PositronicKit
@testable import PKShared

@Suite("Structured Output Service Tests")
@MainActor
struct StructuredOutputServiceTests {
    private struct TagPayload: Decodable, Equatable, Sendable {
        let tags: [String]
    }

    @Test("Decodes typed structured output from native JSON mode")
    func decodesTypedStructuredOutput() async throws {
        let mockClient = MockLLMClient()
        mockClient.nextResponse = "{" + #""tags":["swift","tests"]"# + "}"
        let service = LLMService(storage: MockConfigurationService(), client: mockClient)

        let result = try await service.sendStructured(
            "Extract tags",
            structuredOutput: .jsonObject,
            as: TagPayload.self
        )

        #expect(result == TagPayload(tags: ["swift", "tests"]))
    }

    @Test("Uses JSON object fallback for Ollama structured schema requests")
    func usesJSONFallbackForOllamaSchemaRequests() async throws {
        let mockClient = MockLLMClient()
        mockClient.nextResponse = "{" + #""tags":["swift"]"# + "}"

        let service = LLMService(storage: MockConfigurationService(), client: mockClient)
        try await service.updateConfiguration(.init(provider: .ollama))
        await service.setClients(main: mockClient, utility: nil, fast: nil)

        let schema = StructuredOutputFixtures.tagSchemaDefinition()

        let result = try await service.sendStructured(
            "Extract tags",
            structuredOutput: .jsonSchema(schema),
            as: TagPayload.self
        )

        #expect(result == TagPayload(tags: ["swift"]))
        #expect(mockClient.lastResponseFormat == .jsonObject)
        if let lastMessage = mockClient.lastMessages.last,
           lastMessage.role == .user {
            let content = lastMessage.content
            #expect(content.contains("tag_payload"))
            #expect(content.contains("JSON Schema"))
        } else {
            Issue.record("Expected structured fallback instructions in user prompt")
        }
    }

    @Test("Uses tool shim fallback for openai-compatible low-level streaming")
    func usesToolShimFallbackForOpenAICompatibleStreaming() async throws {
        let mockClient = MockLLMClient()
        mockClient.nextToolCalls = [[MockToolCall(id: "structured-call", name: "emit_structured_response", arguments: "{" + #""tags":["swift"]"# + "}")]]

        let service = LLMService(storage: MockConfigurationService(), client: mockClient)
        try await service.updateConfiguration(.init(provider: .openAICompatible))
        await service.setClients(main: mockClient, utility: nil, fast: nil)

        let schema = StructuredOutputFixtures.tagSchemaDefinition()

        let stream = await service.chatStream(
            messages: [LLMMessage(role: .user, content: "Extract tags")],
            structuredOutput: .jsonSchema(schema)
        )

        var content = ""
        for try await result in stream {
            if let delta = result.choices.first?.delta.content {
                content += delta
            }
            #expect(result.choices.first?.delta.toolCalls == nil)
        }

        #expect(content == "{" + #""tags":["swift"]"# + "}")
        #expect(mockClient.lastResponseFormat == nil)
        #expect(mockClient.lastToolChoice == .function("emit_structured_response"))
        #expect(mockClient.lastTools?.contains(where: { $0.name == "emit_structured_response" }) == true)
    }
}
