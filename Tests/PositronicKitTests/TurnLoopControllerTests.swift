import Foundation
import Logging
import OpenAI
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

/// Isolated tests for `TurnLoopController` (PKARCH-001). These construct the controller
/// directly and drive `runChatLoop` with a hand-built `ChatTurnContext`, bypassing
/// `ChatEngine.execute` and `TurnPreparer` entirely. They exercise the three loop-control
/// behaviors the controller owns: max-turns enforcement, cancellation → STAB-1 partial
/// persistence, and continuation (plugin follow-up resuming the loop).
@Suite(.serialized) @MainActor
struct TurnLoopControllerTests {
    private let timelineId = UUID()

    /// Mirrors `ChatEngineTests.withChatEngineDependencies` but returns a `TurnLoopController`
    /// and its mock collaborators instead of a `ChatEngine`, so the loop is exercised in
    /// isolation from session preparation.
    private func withLoopController<T>(
        streamTimeout: TimeInterval = 60,
        plugins: [any ChatTurnPlugin] = [],
        _ test: @Sendable (TurnLoopController, MockLLMService, MockPersistenceService) async throws -> T
    ) async throws -> T {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspaceCreator: MockWorkspaceCreator()
        )
        let toolRouter = ToolRouter(
            timelineManager: timelineManager,
            messageStore: mockPersistence
        )
        let logger = Logger.module(named: "test-loop-controller")
        let dependencies = ChatEngine.Dependencies(
            timelineManager: timelineManager,
            agentInstanceStore: mockPersistence,
            requestOriginStore: mockPersistence,
            messageStore: mockPersistence,
            llmService: mockLLM,
            toolRouter: toolRouter,
            chatTurnPlugins: plugins,
            streamTimeout: streamTimeout
        )
        let snapshotBuilder = PromptSnapshotBuilder(logger: logger)
        let partialPersistence = PartialAssistantPersistence(
            messageStore: mockPersistence,
            logger: logger
        )
        let controller = TurnLoopController(
            dependencies: dependencies,
            logger: logger,
            additionalStages: [],
            snapshotBuilder: snapshotBuilder,
            partialPersistence: partialPersistence
        )

        let session = Timeline(id: timelineId, title: "Loop Controller Test")
        try await mockPersistence.saveTimeline(session)

        return try await test(controller, mockLLM, mockPersistence)
    }

    private nonisolated func makeContext(
        maxTurns: Int,
        messages: [LLMMessage] = [LLMMessage(role: .user, content: "Hello")],
        tools: [AnyTool] = []
    ) -> ChatTurnContext {
        ChatTurnContext(
            timelineId: timelineId,
            sendId: UUID(),
            agentInstanceId: nil,
            modelName: "test-model",
            maxTurns: maxTurns,
            systemInstructions: nil,
            availableTools: tools,
            contextData: ContextData(),
            remoteDepth: 0,
            currentMessages: messages,
            turnCount: 0,
            outputs: TurnOutputs()
        )
    }

    private nonisolated func runLoop(
        _ controller: TurnLoopController,
        context: ChatTurnContext
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await controller.runChatLoop(continuation: continuation, context: context)
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private nonisolated func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private nonisolated func generationDeltas(_ events: [ChatEvent]) -> [String] {
        events.compactMap { event in
            if case let .delta(event: .generation(text: text)) = event { return text }
            return nil
        }
    }

    // MARK: - Max-turns enforcement

    @Test("Loop stops at maxTurns when a plugin keeps requesting continuation")
    func loopStopsAtMaxTurns() async throws {
        let plugin = AlwaysContinuePlugin()
        try await withLoopController(plugins: [plugin]) { controller, mockLLM, _ in
            mockLLM.mockClient.nextResponses = ["turn-one", "turn-two"]

            let stream = runLoop(controller, context: makeContext(maxTurns: 2))
            let events = try await collect(stream)

            // Two LLM turns ran (one generation delta each) before maxTurns cut the loop.
            let deltas = generationDeltas(events)
            #expect(deltas == ["turn-one", "turn-two"])
            // No cancellation or failure surfaced: the loop finished via the max-turns branch.
            #expect(!events.contains(where: { if case .error = $0 { return true }; return false }))
        }
    }

    // MARK: - Cancellation → STAB-1 .cancelled persistence

    @Test("Cancellation mid-stream persists a .cancelled assistant turn")
    func cancellationPersistsCancelledAssistant() async throws {
        try await withLoopController { controller, mockLLM, mockPersistence in
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamResultFactory.textChunk("Cancelled "))
                continuation.yield(ChatStreamResultFactory.textChunk("mid-stream"))
                continuation.finish(throwing: CancellationError())
            }

            let stream = runLoop(controller, context: makeContext(maxTurns: 5))

            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            let assistantMessages = messages.filter { $0.role == "assistant" }
            #expect(assistantMessages.count == 1)
            let assistant = try #require(assistantMessages.first)
            #expect(assistant.content == "Cancelled mid-stream")
            #expect(assistant.status == .cancelled)
        }
    }

    @Test("Non-cancellation failure persists a .partial assistant turn")
    func failurePersistsPartialAssistant() async throws {
        try await withLoopController { controller, mockLLM, mockPersistence in
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamResultFactory.textChunk("Partial "))
                continuation.yield(ChatStreamResultFactory.textChunk("output"))
                continuation.finish(throwing: NSError(
                    domain: "LoopControllerTest", code: 503,
                    userInfo: [NSLocalizedDescriptionKey: "simulated provider 5xx"]
                ))
            }

            let stream = runLoop(controller, context: makeContext(maxTurns: 5))

            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            let assistantMessages = messages.filter { $0.role == "assistant" }
            #expect(assistantMessages.count == 1)
            let assistant = try #require(assistantMessages.first)
            #expect(assistant.content == "Partial output")
            #expect(assistant.status == .partial)
        }
    }

    // MARK: - Continuation via plugin follow-up

    @Test("Plugin follow-up resumes the loop for a second turn, then finishes")
    func pluginFollowUpResumesLoop() async throws {
        let plugin = InjectOncePlugin()
        try await withLoopController(plugins: [plugin]) { controller, mockLLM, _ in
            mockLLM.mockClient.nextResponses = ["turn-one", "turn-two"]

            let stream = runLoop(controller, context: makeContext(maxTurns: 5))
            let events = try await collect(stream)

            // Both turns ran: the plugin injected a follow-up after turn one, resuming the loop
            // for turn two; on turn two the plugin injected nothing, so the loop finished.
            let deltas = generationDeltas(events)
            #expect(deltas == ["turn-one", "turn-two"])
            #expect(events.contains(where: {
                if case .completion(event: .generationCompleted) = $0 { return true }
                return false
            }))
        }
    }

    @Test("An empty failure (no streamed content) skips partial persistence")
    func emptyFailureSkipsPersistence() async throws {
        try await withLoopController { controller, mockLLM, mockPersistence in
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(
                    domain: "LoopControllerTest", code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "immediate failure"]
                ))
            }

            let stream = runLoop(controller, context: makeContext(maxTurns: 5))

            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            // No assistant content was streamed, so the threshold guard skips persistence.
            #expect(messages.filter { $0.role == "assistant" }.isEmpty)
        }
    }
}

// MARK: - Test Plugins

/// Injects a follow-up user message after the first turn only.
private struct InjectOncePlugin: ChatTurnPlugin {
    func afterTurn(_ turn: CompletedTurn) async throws -> [LLMMessage] {
        turn.turnCount == 1 ? [LLMMessage(role: .user, content: "continue please")] : []
    }
}

/// Injects a follow-up user message after every turn (drives the loop to maxTurns).
private struct AlwaysContinuePlugin: ChatTurnPlugin {
    func afterTurn(_ turn: CompletedTurn) async throws -> [LLMMessage] {
        [LLMMessage(role: .user, content: "keep going")]
    }
}
