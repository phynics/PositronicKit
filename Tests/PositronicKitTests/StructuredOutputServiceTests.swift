import Foundation
@testable import PKContracts
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Testing

@Suite("Structured Output Service Tests")
@MainActor
struct StructuredOutputServiceTests {
    private struct TagPayload: Decodable, Equatable {
        let tags: [String]
    }

    @Test("Decodes typed structured output from native JSON mode")
    func decodesTypedStructuredOutput() async throws {
        let mockClient = MockLLMClient(structuredOutputAdapter: NativeJSONSchemaStructuredOutputAdapter())
        mockClient.nextResponse = "{" + #""tags":["swift","tests"]"# + "}"
        let service = LLMService(
            configuration: .fixture(apiKey: "test-key"),
            clients: .init(primary: mockClient)
        )

        let result = try await service.sendStructured(
            "Extract tags",
            structuredOutput: .jsonObject,
            as: TagPayload.self
        )

        #expect(result == TagPayload(tags: ["swift", "tests"]))
    }

    @Test("Uses schema format and prompt grounding for Ollama structured schema requests")
    func usesSchemaFormatAndPromptGroundingForOllamaSchemaRequests() async throws {
        let mockClient = MockLLMClient(structuredOutputAdapter: PromptAugmentedJSONSchemaAdapter())
        mockClient.nextResponse = "{" + #""tags":["swift"]"# + "}"

        let service = LLMService(
            storage: MockConfigurationService(),
            clientResolver: FixedClientsResolver(clients: .init(primary: mockClient))
        )
        try await service.updateConfiguration(.fixture(activeProvider: .ollama))

        let schema = StructuredOutputFixtures.tagSchemaDefinition()

        let result = try await service.sendStructured(
            "Extract tags",
            structuredOutput: .jsonSchema(schema),
            as: TagPayload.self
        )

        #expect(result == TagPayload(tags: ["swift"]))
        guard case let .jsonSchema(responseSchema) = mockClient.lastResponseFormat else {
            Issue.record("Expected Ollama schema requests to preserve JSON schema response format")
            return
        }
        #expect(responseSchema.name == "tag_payload")
        #expect(responseSchema.schema != nil)
        if let lastMessage = mockClient.lastMessages.last,
           lastMessage.role == .user
        {
            let content = lastMessage.content
            #expect(content.contains("tag_payload"))
            #expect(content.contains("JSON Schema"))
        } else {
            Issue.record("Expected structured fallback instructions in user prompt")
        }
    }

    @Test("Uses native JSON schema response format for OpenAI and OpenRouter")
    func usesNativeJSONSchemaResponseFormatForNativeProviders() async throws {
        for provider in [LLMProvider.openAI, .openRouter] {
            let mockClient = MockLLMClient(structuredOutputAdapter: NativeJSONSchemaStructuredOutputAdapter())
            mockClient.nextResponse = "{" + #""tags":["swift"]"# + "}"

            let service = LLMService(
                storage: MockConfigurationService(),
                clientResolver: FixedClientsResolver(clients: .init(primary: mockClient))
            )
            try await service.updateConfiguration(.fixture(apiKey: "test-key", activeProvider: provider))

            let result = try await service.sendStructured(
                "Extract tags",
                structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition()),
                as: TagPayload.self
            )

            #expect(result == TagPayload(tags: ["swift"]))
            guard case let .jsonSchema(schema) = mockClient.lastResponseFormat else {
                Issue.record("Expected native JSON schema response format for \(provider)")
                continue
            }
            #expect(schema.name == "tag_payload")
            #expect(schema.schema != nil)
            #expect(schema.strict == true)
        }
    }

    @Test("Uses tool shim fallback for Anthropic low-level streaming")
    func usesToolShimFallbackForAnthropicStreaming() async throws {
        let mockClient = MockLLMClient(structuredOutputAdapter: DefaultStructuredOutputAdapter())
        mockClient.nextToolCalls = [[MockToolCall(id: "structured-call", name: "emit_structured_response", arguments: "{" + #""tags":["swift"]"# + "}")]]

        let service = LLMService(
            storage: MockConfigurationService(),
            clientResolver: FixedClientsResolver(clients: .init(primary: mockClient))
        )
        try await service.updateConfiguration(.fixture(apiKey: "test-key", activeProvider: .anthropic))

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

    @Test("Uses native JSON schema response format with prompt augmentation for OpenAI-compatible")
    func usesNativeJSONSchemaForOpenAICompatible() async throws {
        let mockClient = MockLLMClient(structuredOutputAdapter: PromptAugmentedJSONSchemaAdapter())
        mockClient.nextResponse = "{" + #""tags":["swift"]"# + "}"

        let service = LLMService(
            storage: MockConfigurationService(),
            clientResolver: FixedClientsResolver(clients: .init(primary: mockClient))
        )
        try await service.updateConfiguration(.fixture(apiKey: "test-key", activeProvider: .openAICompatible))

        let schema = StructuredOutputFixtures.tagSchemaDefinition()

        let result = try await service.sendStructured(
            "Extract tags",
            structuredOutput: .jsonSchema(schema),
            as: TagPayload.self
        )

        #expect(result == TagPayload(tags: ["swift"]))
        guard case let .jsonSchema(responseSchema) = mockClient.lastResponseFormat else {
            Issue.record("Expected OpenAI-compatible schema requests to use native JSON schema response format")
            return
        }
        #expect(responseSchema.name == "tag_payload")
        #expect(responseSchema.schema != nil)
        #expect(mockClient.lastToolChoice == nil)
        #expect(mockClient.lastTools == nil)
        if let lastMessage = mockClient.lastMessages.last,
           lastMessage.role == .user
        {
            let content = lastMessage.content
            #expect(content.contains("tag_payload"))
            #expect(content.contains("JSON Schema"))
        } else {
            Issue.record("Expected structured fallback instructions in user prompt")
        }
    }

    @Test("Rewrites fragmented Anthropic structured tool output")
    func rewritesFragmentedAnthropicStructuredToolOutput() async throws {
        let mockClient = MockLLMClient(structuredOutputAdapter: DefaultStructuredOutputAdapter())
        mockClient.nextRawStreamChunks = [[
            ChatStreamResultFactory.toolCallChunk(calls: [
                MockToolCall(id: "structured-call", name: "emit_structured_response", arguments: #"{"tags":[""#),
            ]),
            ChatStreamResultFactory.toolCallChunk(calls: [
                MockToolCall(id: "structured-call", name: "emit_structured_response", arguments: #"swift"]}"#),
            ]),
        ]]

        let service = LLMService(
            storage: MockConfigurationService(),
            clientResolver: FixedClientsResolver(clients: .init(primary: mockClient))
        )
        try await service.updateConfiguration(.fixture(apiKey: "test-key", activeProvider: .anthropic))

        let stream = await service.chatStream(
            messages: [LLMMessage(role: .user, content: "Extract tags")],
            structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition())
        )

        var content = ""
        for try await result in stream {
            content += result.choices.first?.delta.content ?? ""
            #expect(result.choices.first?.delta.toolCalls == nil)
        }

        #expect(content == "{" + #""tags":["swift"]"# + "}")
    }

    @Test("Propagates provider stream errors while using structured output")
    func propagatesProviderStreamErrorsWhileUsingStructuredOutput() async throws {
        let mockClient = MockLLMClient()
        mockClient.shouldThrowError = true

        let service = LLMService(
            configuration: .fixture(apiKey: "test-key"),
            clients: .init(primary: mockClient)
        )

        await #expect(throws: LLMStreamError.self) {
            _ = try await service.sendStructured(
                "Extract tags",
                structuredOutput: .jsonObject,
                as: TagPayload.self
            )
        }

        #expect(mockClient.lastResponseFormat == .jsonObject)
    }
}
