import Foundation
import OpenAI
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

// MARK: - PKRR-003: Terminal turn outcomes

/// A failed or cancelled turn must be terminal: after the stream has been finished (with an
/// error or cancellation), the runtime must not invoke `ChatTurnPlugin.afterTurn`, build a
/// follow-up prompt snapshot, append messages, or start another LLM turn. These tests drive
/// the full `ChatEngine` turn loop (not a bare stage) so the outer-loop continuation decision
/// is exercised end to end.
@Suite(.serialized) @MainActor
struct ChatEngineTerminalInvariantTests {
    private let timelineId = UUID()

    /// Mirrors `ChatEngineFailurePersistenceTests.withChatEngineDependencies` but is kept local
    /// and adds a `plugins` parameter so post-terminal plugin activity is observable.
    private func withChatEngineDependencies<T>(
        plugins: [any ChatTurnPlugin] = [],
        _ test: @Sendable (ChatEngine, MockLLMService, MockPersistenceService) async throws -> T
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
        let engine = ChatEngine(
            dependencies: .init(
                timelineManager: timelineManager,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence,
                messageStore: mockPersistence,
                llmService: mockLLM,
                toolRouter: toolRouter,
                chatTurnPlugins: plugins,
                streamTimeout: 60
            )
        )

        let session = Timeline(id: timelineId, title: "PKRR-003 Session")
        try await mockPersistence.saveTimeline(session)

        let wsId = UUID()
        let workspaceRef = WorkspaceReference(
            id: wsId,
            uri: WorkspaceURI(parsing: "pk://local")!,
            location: .runtimeTimeline,
            originID: nil,
            rootPath: "/tmp"
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(wsId, to: timelineId)
        try await mockPersistence.addToolToWorkspace(workspaceId: wsId, tool: .known("mock_tool"))

        try await timelineManager.hydrateTimeline(id: timelineId)

        return try await test(engine, mockLLM, mockPersistence)
    }

    private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    /// Gives the background turn-loop task time to settle after the stream has terminated. In
    /// the buggy code the outer loop continues past the terminal `.stop` signal and invokes
    /// plugin follow-up *after* the consumer has already observed the error/cancellation — this
    /// wait makes that post-terminal activity observable.
    private func waitForPostTerminalActivity() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - No plugin executes after a terminal provider failure

    @Test("No plugin executes after a provider stream failure (PKRR-003)")
    func pluginNotExecutedAfterProviderFailure() async throws {
        let plugin = TerminalPluginRecorder()
        try await withChatEngineDependencies(plugins: [plugin]) { engine, mockLLM, _ in
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamResultFactory.textChunk("partial "))
                continuation.finish(throwing: NSError(
                    domain: "PKRR3ProviderDrop", code: 503,
                    userInfo: [NSLocalizedDescriptionKey: "simulated provider 5xx"]
                ))
            }

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "stream then fail",
                tools: []
            )

            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            try await waitForPostTerminalActivity()

            let callCount = await plugin.afterTurnCallCount
            #expect(callCount == 0, "Plugin must not execute after a terminal provider failure")
        }
    }

    // MARK: - No plugin executes after cancellation

    @Test("No plugin executes after stream cancellation (PKRR-003)")
    func pluginNotExecutedAfterCancellation() async throws {
        let plugin = TerminalPluginRecorder()
        try await withChatEngineDependencies(plugins: [plugin]) { engine, mockLLM, _ in
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamResultFactory.textChunk("cancelled "))
                continuation.finish(throwing: CancellationError())
            }

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "stream then cancel",
                tools: []
            )

            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            try await waitForPostTerminalActivity()

            let callCount = await plugin.afterTurnCallCount
            #expect(callCount == 0, "Plugin must not execute after terminal cancellation")
        }
    }

    // MARK: - No plugin executes after a downstream pipeline-stage failure

    @Test("No plugin executes after a downstream pipeline stage failure (PKRR-003)")
    func pluginNotExecutedAfterPipelineStageFailure() async throws {
        let plugin = TerminalPluginRecorder()
        try await withChatEngineDependencies(plugins: [plugin]) { engine, mockLLM, _ in
            mockLLM.mockClient.nextResponse = "LLM replied successfully"
            var engine = engine
            engine.additionalStages = [FailingStage(error: FailingStageError(message: "stage failure"))]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "succeed LLM then fail stage",
                tools: []
            )

            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            try await waitForPostTerminalActivity()

            let callCount = await plugin.afterTurnCallCount
            #expect(callCount == 0, "Plugin must not execute after a terminal pipeline-stage failure")
        }
    }

    // MARK: - No second LLM turn, message, or prompt-history activity after terminal delivery

    @Test("No second LLM turn or injected message after terminal delivery (PKRR-003)")
    func noSecondLLMTurnOrInjectedMessageAfterTerminalFailure() async throws {
        let plugin = TerminalPluginRecorder(injectedMessages: [
            LLMMessage(role: .user, content: "follow up"),
        ])
        try await withChatEngineDependencies(plugins: [plugin]) { engine, mockLLM, mockPersistence in
            mockLLM.mockClient.shouldThrowError = true
            mockLLM.mockClient.errorToThrow = NSError(
                domain: "PKRR3ProviderDrop", code: 500,
                userInfo: [NSLocalizedDescriptionKey: "simulated provider 5xx"]
            )

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "fail then attempt follow-up",
                tools: []
            )

            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            try await waitForPostTerminalActivity()

            // No plugin follow-up ran.
            let callCount = await plugin.afterTurnCallCount
            #expect(callCount == 0, "Plugin must not execute after a terminal failure")

            // Exactly one provider stream call (the failed turn). A post-terminal follow-up turn
            // would have incremented this.
            #expect(mockLLM.mockClient.streamCallCount == 1, "No second LLM turn after terminal delivery")

            // No plugin-injected user message is persisted.
            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            #expect(!messages.contains(where: { $0.role == "user" && $0.content == "follow up" }),
                    "Plugin-injected message must not be persisted after terminal delivery")
        }
    }

    // MARK: - Regression guard: a successful turn still runs plugin follow-up

    @Test("A successful turn still runs plugin follow-up (PKRR-003 regression guard)")
    func successfulTurnStillRunsPluginFollowUp() async throws {
        let plugin = TerminalPluginRecorder()
        try await withChatEngineDependencies(plugins: [plugin]) { engine, mockLLM, _ in
            mockLLM.mockClient.nextResponse = "All good"

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "succeed",
                tools: []
            )

            _ = try await collect(stream)

            let callCount = await plugin.afterTurnCallCount
            #expect(callCount == 1, "Plugin must still execute after a successful turn")
        }
    }
}

// MARK: - Test Plugins & Stages

/// Records every `afterTurn` invocation and optionally injects follow-up messages to maximally
/// drive the buggy post-terminal continuation path.
private actor TerminalPluginRecorder: ChatTurnPlugin {
    private(set) var afterTurnCalls: [CompletedTurn] = []
    private let injectedMessages: [LLMMessage]

    init(injectedMessages: [LLMMessage] = []) {
        self.injectedMessages = injectedMessages
    }

    var afterTurnCallCount: Int { afterTurnCalls.count }

    func afterTurn(_ turn: CompletedTurn) async throws -> [LLMMessage] {
        afterTurnCalls.append(turn)
        return injectedMessages
    }
}

private struct FailingStageError: Error, Sendable {
    let message: String
}

/// A pipeline stage that always finishes its stream with an error, simulating a failure in a
/// downstream (non-LLM) stage after the LLM stream has completed successfully.
private struct FailingStage: PipelineStage {
    let id = "PKRR3FailingStage"
    private let error: FailingStageError

    init(error: FailingStageError) {
        self.error = error
    }

    func process(_ context: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}
