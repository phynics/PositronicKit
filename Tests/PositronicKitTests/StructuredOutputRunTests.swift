import Foundation
import JSONSchemaBuilder
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

private struct StructuredOutputRunTestsTool: Tool, @unchecked Sendable {
    let callName = "structured_output_run_tests_tool"
    let name = "Structured Output Run Tests Tool"
    let description = "Test tool used to verify ChatRunRequest forwards resolved tools."
    let requiresPermission = false
    let parametersSchema = makeEmptyObjectSchema()

    func canExecute() async -> Bool {
        true
    }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        .success("ok")
    }
}

@Suite("Structured Output Run")
@MainActor
struct StructuredOutputRunTests {
    @Test("run forwards structured output requests to the LLM transport")
    func runForwardsStructuredOutputRequests() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let chat = PositronicKit(configuration: .init(provider: .init(llmService: mockLLM), persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )))

        let request = ChatRunRequest(
            timelineId: UUID(),
            message: "Extract tags",
            tools: [StructuredOutputRunTestsTool().toAnyTool()],
            systemInstructions: "Follow the structured-output instructions exactly.",
            generationParameters: GenerationParameters(temperature: 0.2, maxTokens: 128),
            structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition())
        )
        let stream = try await chat.run(request)

        for try await _ in stream {}

        guard case let .jsonSchema(schema) = mockLLM.mockClient.lastResponseFormat else {
            Issue.record("Expected run() to forward a JSON schema response format")
            return
        }

        #expect(schema.name == "tag_payload")
        let encodedSchema = String(decoding: try JSONEncoder().encode(schema.schema), as: UTF8.self)
        #expect(encodedSchema.contains("\"tags\""))
        #expect(mockLLM.mockClient.lastTools?.map(\.name) == ["structured_output_run_tests_tool"])
        #expect(mockLLM.mockClient.lastParameters?.temperature == 0.2)
        #expect(mockLLM.mockClient.lastParameters?.maxTokens == 128)
        #expect(mockLLM.mockClient.lastMessages.first(where: { $0.role == .system })?.content.contains("structured-output instructions") == true)
    }

    @Test("run has a single overload, so omitting structuredOutput cannot silently select a nil-hardcoding overload")
    func runOmittingStructuredOutputUsesTheSameSingleOverload() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let chat = PositronicKit(configuration: .init(provider: .init(llmService: mockLLM), persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )))

        let stream = try await chat.run(ChatRunRequest(
            timelineId: UUID(),
            message: "Hello"
        ))

        for try await _ in stream {}

        #expect(mockLLM.mockClient.lastResponseFormat == nil)
    }

    @Test("A minimal ChatRunRequest preserves the legacy defaults")
    func minimalChatRunRequestPreservesLegacyDefaults() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let chat = PositronicKit(configuration: .init(provider: .init(llmService: mockLLM), persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )))

        let stream = try await chat.run(ChatRunRequest(
            timelineId: UUID(),
            message: "Hello"
        ))

        for try await _ in stream {}

        #expect(mockLLM.mockClient.lastTools == nil)
        #expect(mockLLM.mockClient.lastResponseFormat == nil)
        #expect(mockLLM.mockClient.lastParameters == nil)
        #expect(mockLLM.mockClient.lastMessages.contains { $0.role == .tool } == false)
    }

    @Test("passing no sidecars preserves the exact no-sidecar runtime path")
    func noSidecarsPreservesNoSidecarRuntimePath() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let chat = PositronicKit(configuration: .init(provider: .init(llmService: mockLLM), persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )))

        let stream = try await chat.run(ChatRunRequest(
            timelineId: UUID(),
            message: "Hello",
            sidecars: []
        ))

        for try await _ in stream {}

        #expect(mockLLM.mockClient.lastResponseFormat == nil)
    }
}
