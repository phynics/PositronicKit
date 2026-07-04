import Foundation
import JSONSchemaBuilder
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Sidecar turn integration")
@MainActor
struct SidecarTurnIntegrationTests {
    private var directives: [SidecarDirective] {
        [
            .init(name: "title", instruction: "Short title; null to decline.", schema: JSONString().definition(), streaming: .buffered),
            .init(name: "tone", instruction: "One-word tone.", schema: JSONString().definition(), streaming: .buffered),
        ]
    }

    private func makeChat(llmService: MockLLMService, persistence: MockPersistenceService) -> PositronicKit {
        PositronicKit(
            llmService: llmService,
            persistence: .init(
                messageStore: persistence,
                timelinePersistence: persistence,
                workspacePersistence: persistence,
                memoryStore: persistence,
                toolPersistence: persistence,
                agentInstanceStore: persistence,
                requestOriginStore: persistence
            )
        )
    }

    @Test("Turn with sidecars streams response only and surfaces directive results")
    func turnWithSidecarsStreamsResponseAndDirectives() async throws {
        let mockLLM = MockLLMService()
        mockLLM.mockClient.nextChunks = [[
            #"{"response": "Hi there", "sidecar_payload": {"title": "Greeting", "tone": "warm"}}"#,
        ]]
        let persistence = MockPersistenceService()
        let chat = makeChat(llmService: mockLLM, persistence: persistence)
        let timelineId = UUID()

        let stream = try await chat.run(ChatRunRequest(
            timelineId: timelineId,
            message: "hello",
            sidecars: directives
        ))

        var events: [ChatEvent] = []
        for try await event in stream {
            events.append(event)
        }

        let generationText = events.compactMap(\.textContent).joined()
        #expect(generationText == "Hi there")

        let results = events.compactMap(\.sidecarResults).flatMap { $0 }
        #expect(results.contains(SidecarResult(name: "title", outcome: .value(AnyCodable("Greeting")))))
        #expect(results.contains(SidecarResult(name: "tone", outcome: .value(AnyCodable("warm")))))

        #expect(persistence.messages.last?.content == "Hi there")
    }

    @Test("Passing both structuredOutput and sidecars throws a conflict error")
    func structuredOutputAndSidecarsConflict() async throws {
        let mockLLM = MockLLMService()
        let persistence = MockPersistenceService()
        let chat = makeChat(llmService: mockLLM, persistence: persistence)

        await #expect(throws: SidecarError.conflictsWithExplicitStructuredOutput) {
            _ = try await chat.run(ChatRunRequest(
                timelineId: UUID(),
                message: "hello",
                structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition()),
                sidecars: directives
            ))
        }
    }

    @Test("Instruction block and combined schema reach the LLM request via the user message")
    func instructionBlockAndSchemaReachRequest() async throws {
        let mockLLM = MockLLMService()
        mockLLM.mockClient.nextChunks = [[
            #"{"response": "ok", "sidecar_payload": {"title": "T", "tone": "flat"}}"#,
        ]]
        let persistence = MockPersistenceService()
        let chat = makeChat(llmService: mockLLM, persistence: persistence)

        let stream = try await chat.run(ChatRunRequest(
            timelineId: UUID(),
            message: "hello",
            sidecars: directives
        ))
        for try await _ in stream {}

        let lastMessage = try #require(mockLLM.mockClient.lastMessages.last)
        #expect(lastMessage.role == .user)
        #expect(lastMessage.content.contains("hello"))
        #expect(lastMessage.content.contains("## Piggy-backed fields"))
        #expect(lastMessage.content.contains("title"))
        #expect(lastMessage.content.contains("Short title; null to decline."))
        #expect(lastMessage.content.contains("tone"))

        guard case let .jsonSchema(schema) = mockLLM.mockClient.lastResponseFormat else {
            Issue.record("Expected run(sidecars:) to request a combined JSON schema")
            return
        }
        #expect(schema.name == "sidecar_turn")

        // System message must be byte-identical to a run without sidecars — the directive
        // list must not leak into the cache-stable system prefix.
        let mockLLMWithout = MockLLMService()
        mockLLMWithout.mockClient.nextChunks = [["ok"]]
        let chatWithout = makeChat(llmService: mockLLMWithout, persistence: MockPersistenceService())
        let streamWithout = try await chatWithout.run(ChatRunRequest(
            timelineId: UUID(),
            message: "hello"
        ))
        for try await _ in streamWithout {}

        let systemMessage = mockLLM.mockClient.lastMessages.first { $0.role == .system }
        let systemMessageWithout = mockLLMWithout.mockClient.lastMessages.first { $0.role == .system }
        #expect(systemMessage?.content == systemMessageWithout?.content)
        #expect(systemMessage?.content.contains("Piggy-backed") != true)
    }

    @Test("Sidecar instruction block survives a tool-call turn and reaches every request")
    func multiTurnSidecarInstructionPersists() async throws {
        struct MockTool: PKShared.Tool, @unchecked Sendable {
            let id = "mock_tool"
            let name = "mock_tool"
            let description = "A mock tool for testing"
            let requiresPermission = false
            let parametersSchema: [String: AnyCodable] = [:]

            func canExecute() async -> Bool {
                true
            }

            func execute(parameters _: [String: Any]) async throws -> ToolResult {
                .success("Tool result")
            }
        }

        let mockLLM = MockLLMService()
        mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool")]]
        mockLLM.mockClient.nextChunks = [
            [""],
            [#"{"response": "done", "sidecar_payload": {"title": "T", "tone": "flat"}}"#],
        ]
        let persistence = MockPersistenceService()
        let chat = makeChat(llmService: mockLLM, persistence: persistence)

        let stream = try await chat.run(ChatRunRequest(
            timelineId: UUID(),
            message: "hello",
            tools: [MockTool().toAnyTool()],
            sidecars: directives
        ))
        for try await _ in stream {}

        #expect(mockLLM.mockClient.messageHistory.count == 2)

        for callMessages in mockLLM.mockClient.messageHistory {
            let userMessages = callMessages.filter { $0.role == .user }
            #expect(userMessages.contains { $0.content.contains("## Piggy-backed fields") })
            let systemMessages = callMessages.filter { $0.role == .system }
            #expect(systemMessages.allSatisfy { !$0.content.contains("Piggy-backed") })
        }
    }

    @Test("System section stays byte-stable across changing directive sets")
    func systemSectionStableAcrossDirectiveSets() async throws {
        let directivesB: [SidecarDirective] = [
            .init(name: "summary", instruction: "One sentence summary.", schema: JSONString().definition(), streaming: .buffered),
        ]

        let mockLLMA = MockLLMService()
        mockLLMA.mockClient.nextChunks = [[#"{"response": "ok", "sidecar_payload": {"title": "T", "tone": "flat"}}"#]]
        let chatA = makeChat(llmService: mockLLMA, persistence: MockPersistenceService())
        let streamA = try await chatA.run(ChatRunRequest(
            timelineId: UUID(),
            message: "hello",
            sidecars: directives
        ))
        for try await _ in streamA {}

        let mockLLMB = MockLLMService()
        mockLLMB.mockClient.nextChunks = [[#"{"response": "ok", "sidecar_payload": {"summary": "S"}}"#]]
        let chatB = makeChat(llmService: mockLLMB, persistence: MockPersistenceService())
        let streamB = try await chatB.run(ChatRunRequest(
            timelineId: UUID(),
            message: "hello",
            sidecars: directivesB
        ))
        for try await _ in streamB {}

        let mockLLMEmpty = MockLLMService()
        mockLLMEmpty.mockClient.nextChunks = [["ok"]]
        let chatEmpty = makeChat(llmService: mockLLMEmpty, persistence: MockPersistenceService())
        let streamEmpty = try await chatEmpty.run(ChatRunRequest(
            timelineId: UUID(),
            message: "hello",
            sidecars: []
        ))
        for try await _ in streamEmpty {}

        let systemA = mockLLMA.mockClient.lastMessages.first { $0.role == .system }?.content
        let systemB = mockLLMB.mockClient.lastMessages.first { $0.role == .system }?.content
        let systemEmpty = mockLLMEmpty.mockClient.lastMessages.first { $0.role == .system }?.content

        #expect(systemA == systemB)
        #expect(systemB == systemEmpty)
    }

    @Test("Mechanism preamble is stable, name-free system text opt-in")
    func preambleOptInAddsStableSystemText() async throws {
        let mockLLMWith = MockLLMService()
        mockLLMWith.mockClient.nextChunks = [[#"{"response": "ok", "sidecar_payload": {"title": "T", "tone": "flat"}}"#]]
        let chatWith = makeChat(llmService: mockLLMWith, persistence: MockPersistenceService())
        let streamWith = try await chatWith.run(ChatRunRequest(
            timelineId: UUID(),
            message: "hello",
            sidecars: directives,
            includeSidecarMechanismPreamble: true
        ))
        for try await _ in streamWith {}

        let mockLLMEmpty = MockLLMService()
        mockLLMEmpty.mockClient.nextChunks = [["ok"]]
        let chatEmpty = makeChat(llmService: mockLLMEmpty, persistence: MockPersistenceService())
        let streamEmpty = try await chatEmpty.run(ChatRunRequest(
            timelineId: UUID(),
            message: "hello",
            sidecars: [],
            includeSidecarMechanismPreamble: true
        ))
        for try await _ in streamEmpty {}

        let systemWith = mockLLMWith.mockClient.lastMessages.first { $0.role == .system }?.content
        let systemEmpty = mockLLMEmpty.mockClient.lastMessages.first { $0.role == .system }?.content

        #expect(systemWith?.contains(SidecarSchemaComposer.mechanismPreamble) == true)
        #expect(systemWith == systemEmpty)
        #expect(systemWith?.contains("title") != true)
        #expect(systemWith?.contains("tone") != true)
    }

    @Test("Preamble opt-in preserves default system instructions when none are supplied")
    func defaultInstructionsSurvivePreambleWithNilSystemInstructions() async throws {
        let mockLLM = MockLLMService()
        mockLLM.mockClient.nextChunks = [["ok"]]
        let chat = makeChat(llmService: mockLLM, persistence: MockPersistenceService())
        let stream = try await chat.run(ChatRunRequest(
            timelineId: UUID(),
            message: "hello",
            includeSidecarMechanismPreamble: true
        ))
        for try await _ in stream {}

        let system = mockLLM.mockClient.lastMessages.first { $0.role == .system }?.content
        #expect(system?.contains(SidecarSchemaComposer.mechanismPreamble) == true)
        #expect(system?.isEmpty == false)
    }

    @Test("Turn with sidecars: [] behaves identically to a turn without the parameter")
    func emptySidecarsIsANoOp() async throws {
        let mockLLMWithout = MockLLMService()
        mockLLMWithout.mockClient.nextChunks = [["Hello"]]
        let persistenceWithout = MockPersistenceService()
        let chatWithout = makeChat(llmService: mockLLMWithout, persistence: persistenceWithout)

        let mockLLMWith = MockLLMService()
        mockLLMWith.mockClient.nextChunks = [["Hello"]]
        let persistenceWith = MockPersistenceService()
        let chatWith = makeChat(llmService: mockLLMWith, persistence: persistenceWith)

        let streamWithout = try await chatWithout.run(ChatRunRequest(
            timelineId: UUID(),
            message: "hi"
        ))
        var signaturesWithout: [String] = []
        for try await event in streamWithout {
            signaturesWithout.append(Self.signature(for: event))
        }

        let streamWith = try await chatWith.run(ChatRunRequest(
            timelineId: UUID(),
            message: "hi",
            sidecars: []
        ))
        var signaturesWith: [String] = []
        for try await event in streamWith {
            signaturesWith.append(Self.signature(for: event))
        }

        #expect(signaturesWithout == signaturesWith)
        #expect(mockLLMWithout.mockClient.lastResponseFormat == nil)
        #expect(mockLLMWith.mockClient.lastResponseFormat == nil)
    }

    /// Event-type + content signature, deliberately excluding message id/timestamp/duration
    /// fields that legitimately differ between two independent turns.
    private static func signature(for event: ChatEvent) -> String {
        switch event {
        case let .meta(event: .generationContext(metadata)):
            return "generationContext(\(metadata.memories), \(metadata.files))"
        case let .delta(event: .generation(text)):
            return "generation(\(text))"
        case let .completion(event: .generationCompleted(message, _)):
            return "generationCompleted(\(message.content))"
        default:
            return String(describing: event)
        }
    }
}
