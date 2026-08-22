import PKTestSupport
import Testing
@testable import PositronicKit
@testable import PKContracts
import PKUtilities

@Suite("Structured Output Prompt Flow Tests")
@MainActor
struct StructuredOutputPromptFlowTests {
    @Test("generationStreamWithContext preserves prompt context with json object output")
    func generationStreamWithContextPreservesPromptContext() async throws {
        let mockClient = MockLLMClient(structuredOutputAdapter: PromptAugmentedJSONSchemaAdapter())
        mockClient.nextChunks = [["{\"tags\":[\"swift\"]}"]]
        let service = LLMService(
            configuration: .fixture(apiKey: "test-key"),
            clients: .init(primary: mockClient)
        )

        let request = LLMGenerationRequest(
            userQuery: "Extract tags",
            contextNotes: [ContextNote(name: "Note", content: "Prompt note", source: "note")],
            memories: [],
            chatHistory: [Message(content: "Earlier question", role: .user)],
            tools: [],
            workspaces: [],
            primaryWorkspace: nil,
            requestOriginName: nil,
            systemInstructions: "System rules",
            structuredOutput: .jsonObject
        )

        let result = try await service.generationStreamWithContext(request)

        var chunks: [String] = []
        for try await event in result.stream {
            if let chunk = event.choices.first?.delta.content {
                chunks.append(chunk)
            }
        }

        #expect(chunks.joined() == "{\"tags\":[\"swift\"]}")
        #expect(mockClient.lastResponseFormat == .jsonObject)
        #expect(result.rawPrompt.contains("System rules"))
        #expect(result.rawPrompt.contains("Prompt note"))
        #expect(result.rawPrompt.contains("Extract tags"))
    }

    @Test("generationStreamWithContext includes fallback schema instructions in raw prompt")
    func generationStreamWithContextIncludesFallbackSchemaInstructions() async throws {
        let mockClient = MockLLMClient(structuredOutputAdapter: PromptAugmentedJSONSchemaAdapter())
        mockClient.nextChunks = [["{\"tags\":[\"swift\"]}"]]
        let service = LLMService(
            storage: MockConfigurationService(),
            clientResolver: FixedClientsResolver(clients: .init(primary: mockClient))
        )
        try await service.updateConfiguration(.fixture(activeProvider: .ollama))

        let request = LLMGenerationRequest(
            userQuery: "Extract tags",
            contextNotes: [],
            memories: [],
            chatHistory: [],
            tools: [],
            workspaces: [],
            primaryWorkspace: nil,
            requestOriginName: nil,
            systemInstructions: "System rules",
            structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition())
        )

        let result = try await service.generationStreamWithContext(request)

        var chunks: [String] = []
        for try await event in result.stream {
            if let chunk = event.choices.first?.delta.content {
                chunks.append(chunk)
            }
        }

        #expect(chunks.joined() == "{\"tags\":[\"swift\"]}")
        guard case let .jsonSchema(responseSchema) = mockClient.lastResponseFormat else {
            Issue.record("Expected Ollama schema requests to preserve JSON schema response format")
            return
        }
        #expect(responseSchema.name == "tag_payload")
        #expect(responseSchema.schema != nil)
        #expect(result.rawPrompt.contains("System rules"))
        #expect(result.rawPrompt.contains("Schema name: tag_payload"))
        #expect(result.rawPrompt.contains("JSON Schema"))
    }

    @Test("generationStreamWithContext preserves Anthropic schema constraints and rewrites synthetic tool output")
    func generationStreamWithContextPreservesAnthropicSchemaConstraints() async throws {
        let mockClient = MockLLMClient(structuredOutputAdapter: DefaultStructuredOutputAdapter())
        mockClient.nextRawStreamChunks = [[
            GenerationStreamResultFactory.toolCallChunk(calls: [
                MockToolCall(
                    id: "structured-call",
                    name: "emit_structured_response",
                    arguments: #"{"tags":["swift"]}"#
                )
            ])
        ]]

        let service = LLMService(
            storage: MockConfigurationService(),
            clientResolver: FixedClientsResolver(clients: .init(primary: mockClient))
        )
        try await service.updateConfiguration(.fixture(apiKey: "test-key", activeProvider: .anthropic))

        let request = LLMGenerationRequest(
            userQuery: "Extract tags",
            contextNotes: [],
            memories: [],
            chatHistory: [],
            tools: [],
            workspaces: [],
            primaryWorkspace: nil,
            requestOriginName: nil,
            systemInstructions: "System rules",
            structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition())
        )

        let result = try await service.generationStreamWithContext(request)

        var content = ""
        for try await event in result.stream {
            #expect(event.choices.first?.delta.toolCalls == nil)
            content += event.choices.first?.delta.content ?? ""
        }

        #expect(content == #"{"tags":["swift"]}"#)
        #expect(mockClient.lastResponseFormat == nil)
        #expect(mockClient.lastToolChoice == .function("emit_structured_response"))
        #expect(mockClient.lastTools?.contains(where: { $0.name == "emit_structured_response" }) == true)
        #expect(result.rawPrompt.contains("System rules"))
    }

    @Test("generationStreamWithContext preserves OpenAI-compatible schema constraints with native response format")
    func generationStreamWithContextPreservesOpenAICompatibleSchemaConstraints() async throws {
        let mockClient = MockLLMClient(structuredOutputAdapter: PromptAugmentedJSONSchemaAdapter())
        mockClient.nextChunks = [["{\"tags\":[\"swift\"]}"]]

        let service = LLMService(
            storage: MockConfigurationService(),
            clientResolver: FixedClientsResolver(clients: .init(primary: mockClient))
        )
        try await service.updateConfiguration(.fixture(apiKey: "test-key", activeProvider: .openAICompatible))

        let request = LLMGenerationRequest(
            userQuery: "Extract tags",
            contextNotes: [],
            memories: [],
            chatHistory: [],
            tools: [],
            workspaces: [],
            primaryWorkspace: nil,
            requestOriginName: nil,
            systemInstructions: "System rules",
            structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition())
        )

        let result = try await service.generationStreamWithContext(request)

        var chunks: [String] = []
        for try await event in result.stream {
            if let chunk = event.choices.first?.delta.content {
                chunks.append(chunk)
            }
        }

        #expect(chunks.joined() == "{\"tags\":[\"swift\"]}")
        guard case let .jsonSchema(responseSchema) = mockClient.lastResponseFormat else {
            Issue.record("Expected OpenAI-compatible schema requests to use native JSON schema response format")
            return
        }
        #expect(responseSchema.name == "tag_payload")
        #expect(responseSchema.schema != nil)
        #expect(mockClient.lastToolChoice == nil)
        #expect(mockClient.lastTools == nil)
        #expect(result.rawPrompt.contains("System rules"))
        #expect(result.rawPrompt.contains("Schema name: tag_payload"))
        #expect(result.rawPrompt.contains("JSON Schema"))
    }
}
