import PKTestSupport
import Testing
@testable import PositronicKit
@testable import PKShared

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
        try await service.updateConfiguration(.init(provider: .ollama))
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
}
