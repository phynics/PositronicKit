import Foundation
import PKContracts
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Testing

/// Runtime behavior of the `GenerationTransport` selection introduced for issue #236 phase 2.
///
/// `.streaming` (the default) keeps the existing chunk-by-chunk path. `.requestResponse`
/// asks the service for one complete response and delivers it as a single terminal chunk, so
/// every downstream Turn stage sees the same `AsyncThrowingStream<LLMStreamChunk, Error>`.
@Suite("Generation transport selection", .tags(.integration))
struct GenerationTransportTests {
    @Test("a request-response managed Turn emits one generation delta and matches streaming durability")
    func requestResponseManagedTurnMatchesStreaming() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [["stream", "-", "reply"], ["request", "-", "reply"]]
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Transport")
        let agent = try await kit.agents.create(name: "Transport Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)

        let streaming = try await timeline.startTurn("streaming")
        let streamingEvents = await streaming.events().collect()
        let streamingDeltas = generationDeltas(in: streamingEvents)

        let requestResponse = try await timeline.startTurn(
            "request-response",
            options: TurnOptions(transport: .requestResponse)
        )
        let requestResponseEvents = await requestResponse.events().collect()
        let requestResponseDeltas = generationDeltas(in: requestResponseEvents)

        #expect(streamingDeltas == ["stream", "-", "reply"])
        #expect(requestResponseDeltas == ["request-reply"])

        let repository = kit.runtimeRepository
        let assistantMessages = try await repository.fetchMessages(for: timeline.id)
            .filter { $0.role == "assistant" }
        #expect(assistantMessages.map(\.content) == ["stream-reply", "request-reply"])
        #expect(assistantMessages.allSatisfy { $0.toMessage().toolCalls == nil })
        #expect(assistantMessages.last?.executionKind == .agentManaged)

        let terminalRecords = requestResponseEvents.compactMap { event -> Message? in
            if case let .completion(.generationCompleted(message, _)) = event {
                return message
            }
            return nil
        }
        #expect(terminalRecords.count == 1)
        #expect(terminalRecords.first?.content == "request-reply")
    }

    @Test("a request-response Turn round-trips tool calls through the normal pipeline")
    func requestResponseTurnRoundTripsToolCalls() async throws {
        let workspace = TestWorkspace()
        let llm = MockLLMService()
        let persistence = MockPersistenceService()

        struct GreetingTool: PKTool {
            let callName = "transport_greet"
            let name = "Transport Greeting"
            let toolDescription = "Greets a user by name."
            let requiresPermission = false
            let parametersSchema = makeEmptyObjectSchema()

            func canExecute() async -> Bool {
                true
            }

            func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
                let name = parameters["name"]?.value as? String ?? "friend"
                return .success("Hello, \(name)!")
            }
        }

        llm.mockClient.nextToolCalls = [[MockToolCall(
            id: "transport-call",
            name: "transport_greet",
            arguments: #"{"name":"Taylor"}"#
        )]]
        llm.mockClient.nextResponses = ["", "I greeted Taylor successfully."]

        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: PKRuntime.PersistenceConfiguration(
                runtimeRepository: persistence,
                workspacePersistence: persistence,
                agentStore: persistence,
                requestOriginStore: persistence
            ),
            runtime: .init(
                workspaceProfile: .hostManaged(root: workspace.root),
                workspaceCreator: MockWorkspaceCreator()
            )
        ))
        let timeline = try await kit.timelines.create(title: "RR tool")
        let tool = AnyTool(GreetingTool())
        let workspaceReference = WorkspaceReference(
            uri: WorkspaceURI(host: "pk-runtime", path: workspace.root.path),
            location: .runtime,
            rootPath: workspace.root.path
        )
        try await persistence.saveWorkspace(workspaceReference)
        try await persistence.addToolToWorkspace(
            workspaceID: workspaceReference.id,
            tool: tool.identity
        )
        try await kit.timelines.attachWorkspace(workspaceReference.id, to: timeline.id)

        let events = try await kit.turnEngine.run(TurnRequest(
            timelineID: timeline.id,
            message: "Greet Taylor using the available tool.",
            tools: [tool],
            transport: .requestResponse
        )).collect()

        #expect(events.contains { event in
            if case let .completion(.toolExecution(id, status)) = event,
               id == "transport-call",
               case .success = status
            {
                return true
            }
            return false
        })
        #expect(events.contains { event in
            if case let .delta(.generation(text)) = event {
                return text.contains("I greeted Taylor successfully.")
            }
            return false
        })
        #expect(events.contains { event in
            if case .completion(.generationCompleted) = event { return true }
            return false
        })

        let messages = try await persistence.fetchMessages(for: timeline.id)
        let toolMessage = try #require(messages.first { $0.role == "tool" })
        #expect(toolMessage.toolCallID == "transport-call")
        #expect(toolMessage.content.contains("Hello, Taylor!"))
    }

    @Test("structured output decodes identically on both transports")
    func structuredOutputDecodesIdentically() async throws {
        let payload = #"{"tags":["swift","agents"]}"#
        let request = StructuredOutputRequest.jsonSchema(StructuredOutputFixtures.tagSchemaDefinition())

        let streamingNative = try await structuredPayload(transport: .streaming, structuredOutput: request) { llm in
            try await llm.updateConfiguration(.fixture(activeProvider: .openAICompatible))
            llm.mockClient.nextChunks = [[payload]]
        }
        let requestResponseNative = try await structuredPayload(transport: .requestResponse, structuredOutput: request) { llm in
            try await llm.updateConfiguration(.fixture(activeProvider: .openAICompatible))
            llm.mockClient.nextChunks = [[payload]]
        }
        #expect(streamingNative == payload)
        #expect(requestResponseNative == payload)

        let streamingSynthetic = try await structuredPayload(transport: .streaming, structuredOutput: request) { llm in
            try await llm.updateConfiguration(.fixture(activeProvider: .anthropic))
            llm.mockClient = MockLLMClient(structuredOutputAdapter: DefaultStructuredOutputAdapter())
            llm.mockClient.nextToolCalls = [[MockToolCall(
                id: "structured-call",
                name: "emit_structured_response",
                arguments: payload
            )]]
        }
        let requestResponseSynthetic = try await structuredPayload(transport: .requestResponse, structuredOutput: request) { llm in
            try await llm.updateConfiguration(.fixture(activeProvider: .anthropic))
            llm.mockClient = MockLLMClient(structuredOutputAdapter: DefaultStructuredOutputAdapter())
            llm.mockClient.nextToolCalls = [[MockToolCall(
                id: "structured-call",
                name: "emit_structured_response",
                arguments: payload
            )]]
        }
        #expect(streamingSynthetic == payload)
        #expect(requestResponseSynthetic == payload)

        let decoded = try StructuredOutputDecoder.decode([String: [String]].self, from: requestResponseSynthetic)
        #expect(decoded["tags"] == ["swift", "agents"])
    }

    @Test("a request-response one-shot stream delivers one chunk")
    func requestResponseOneShotStreamDeliversOneChunk() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [["one", " ", "chunk"]]
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .init(runtimeRepository: InMemoryTimelineRuntimeRepository())
        ))

        var chunks: [String] = []
        for try await chunk in kit.model.stream("hi", transport: .requestResponse) {
            chunks.append(chunk.choices.first?.delta.content ?? "")
        }

        #expect(chunks == ["one chunk"])
    }

    @Test("cancelling a request-response Turn cancels the in-flight provider call")
    func cancellingRequestResponseTurnCancelsProvider() async throws {
        let llm = MockLLMService()
        llm.mockClient.neverFinishingStreamCallIndices = [1]
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "RR cancel")
        let agent = try await kit.agents.create(name: "Cancel Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)

        let turn = try await timeline.startTurn(
            "hello",
            options: TurnOptions(transport: .requestResponse)
        )
        while llm.mockClient.neverFinishingStreamStartCount < 1 {
            await Task.yield()
        }
        await turn.cancel()

        let events = await turn.events().collect()
        #expect(events.contains { event in
            if case .error(.generationCancelled) = event { return true }
            return false
        })
        #expect(try await turn.outcome() == .cancelled(reason: "Turn task cancelled."))
        #expect(llm.mockClient.generationCaptureHistory.count == 1)
    }

    // MARK: - Helpers

    private func generationDeltas(in events: [TurnEvent]) -> [String] {
        events.compactMap { event in
            if case let .delta(.generation(text)) = event { return text }
            return nil
        }
    }

    private func structuredPayload(
        transport: GenerationTransport,
        structuredOutput: StructuredOutputRequest,
        configure: (MockLLMService) async throws -> Void
    ) async throws -> String {
        let llm = MockLLMService()
        try await configure(llm)
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .init(runtimeRepository: InMemoryTimelineRuntimeRepository())
        ))
        return try await kit.model.generate(
            "extract tags",
            structuredOutput: structuredOutput,
            transport: transport
        )
    }
}
