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
            clientName: nil,
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
            clientName: nil,
            systemInstructions: "System rules",
            structuredOutput: .jsonSchema(StructuredOutputSchema(
                name: "tag_payload",
                schema: [
                    "type": AnyCodable.string("object"),
                    "properties": AnyCodable.dictionary([
                        "tags": .dictionary([
                            "type": .string("array"),
                            "items": .dictionary(["type": .string("string")])
                        ])
                    ]),
                    "required": AnyCodable.array([.string("tags")])
                ]
            ))
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
        #expect(result.rawPrompt.contains("Schema name: tag_payload"))
        #expect(result.rawPrompt.contains("JSON Schema"))
    }
}
