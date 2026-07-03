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
            #"{"response": "Hi there", "title": "Greeting", "tone": "warm"}"#,
        ]]
        let persistence = MockPersistenceService()
        let chat = makeChat(llmService: mockLLM, persistence: persistence)
        let timelineId = UUID()

        let stream = try await chat.run(timelineId: timelineId, message: "hello", sidecars: directives)

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
            _ = try await chat.run(
                timelineId: UUID(),
                message: "hello",
                structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition()),
                sidecars: directives
            )
        }
    }

    @Test("Instruction block and combined schema reach the LLM request")
    func instructionBlockAndSchemaReachRequest() async throws {
        let mockLLM = MockLLMService()
        mockLLM.mockClient.nextChunks = [[
            #"{"response": "ok", "title": "T", "tone": "flat"}"#,
        ]]
        let persistence = MockPersistenceService()
        let chat = makeChat(llmService: mockLLM, persistence: persistence)

        let stream = try await chat.run(timelineId: UUID(), message: "hello", sidecars: directives)
        for try await _ in stream {}

        let sentText = mockLLM.mockClient.lastMessages.map(\.content).joined(separator: "\n")
        #expect(sentText.contains("title"))
        #expect(sentText.contains("Short title; null to decline."))
        #expect(sentText.contains("tone"))

        guard case let .jsonSchema(schema) = mockLLM.mockClient.lastResponseFormat else {
            Issue.record("Expected run(sidecars:) to request a combined JSON schema")
            return
        }
        #expect(schema.name == "sidecar_turn")
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

        let streamWithout = try await chatWithout.run(timelineId: UUID(), message: "hi")
        var signaturesWithout: [String] = []
        for try await event in streamWithout {
            signaturesWithout.append(Self.signature(for: event))
        }

        let streamWith = try await chatWith.run(timelineId: UUID(), message: "hi", sidecars: [])
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
