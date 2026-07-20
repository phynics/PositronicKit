import PKTestSupport
import Testing
@testable import PositronicKit
@testable import PKShared
import PKUtilities

@Suite("Structured Output Prompt Flow Tests")
@MainActor
struct StructuredOutputPromptFlowTests {
    @Test("chatStreamWithContext preserves prompt context with json object output")
    func chatStreamWithContextPreservesPromptContext() async throws {
        let mockClient = MockLLMClient()
        mockClient.nextChunks = [["{\"tags\":[\"swift\"]}"]]
        let service = LLMService(storage: MockConfigurationService(), client: mockClient)

        let request = LLMChatRequest(
            userQuery: "Extract tags",
            contextNotes: [ContextFile(name: "Note", content: "Prompt note", source: "note")],
            memories: [],
            chatHistory: [Message(content: "Earlier question", role: .user)],
            tools: [],
            workspaces: [],
            primaryWorkspace: nil,
            requestOriginName: nil,
            systemInstructions: "System rules",
            structuredOutput: .jsonObject
        )

        let result = try await service.chatStreamWithContext(request)

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

    @Test("chatStreamWithContext includes fallback schema instructions in raw prompt")
    func chatStreamWithContextIncludesFallbackSchemaInstructions() async throws {
        let mockClient = MockLLMClient()
        mockClient.nextChunks = [["{\"tags\":[\"swift\"]}"]]
        let service = LLMService(storage: MockConfigurationService(), client: mockClient)
        try await service.updateConfiguration(.fixture(activeProvider: .ollama))
        await service.setClients(main: mockClient, utility: nil, fast: nil)

        let request = LLMChatRequest(
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

        let result = try await service.chatStreamWithContext(request)

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

    @Test("chatStreamWithContext preserves Anthropic schema constraints and rewrites synthetic tool output")
    func chatStreamWithContextPreservesAnthropicSchemaConstraints() async throws {
        let mockClient = MockLLMClient()
        mockClient.nextRawStreamChunks = [[
            ChatStreamResultFactory.toolCallChunk(calls: [
                MockToolCall(
                    id: "structured-call",
                    name: "emit_structured_response",
                    arguments: #"{"tags":["swift"]}"#
                )
            ])
        ]]

        let service = LLMService(storage: MockConfigurationService(), client: mockClient)
        try await service.updateConfiguration(.fixture(activeProvider: .anthropic))
        await service.setClients(main: mockClient, utility: nil, fast: nil)

        let request = LLMChatRequest(
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

        let result = try await service.chatStreamWithContext(request)

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

    @Test("chatStreamWithContext preserves OpenAI-compatible schema constraints with native response format")
    func chatStreamWithContextPreservesOpenAICompatibleSchemaConstraints() async throws {
        let mockClient = MockLLMClient()
        mockClient.nextChunks = [["{\"tags\":[\"swift\"]}"]]

        let service = LLMService(storage: MockConfigurationService(), client: mockClient)
        try await service.updateConfiguration(.fixture(activeProvider: .openAICompatible))
        await service.setClients(main: mockClient, utility: nil, fast: nil)

        let request = LLMChatRequest(
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

        let result = try await service.chatStreamWithContext(request)

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
