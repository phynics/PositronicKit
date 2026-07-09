import Foundation
import Logging
import PKPrompt
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

private final class CapturingLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

private struct CapturingLogHandler: LogHandler {
    let sink: CapturingLogSink
    var logLevel: Logger.Level = .debug
    var metadata = Logger.Metadata()

    subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level _: Logger.Level,
        message: Logger.Message,
        metadata _: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        sink.append(message.description)
    }
}

@Suite("Public runtime stories", .serialized)
struct PublicRuntimeStoriesTests {
    @Test("promptAssemblyLogger surfaces prompt-assembly diagnostics through the facade")
    func promptAssemblyLoggerEmitsDiagnostics() async throws {
        let (chat, mockLLM, _, timelineId, _) = try await makeAcceptanceRuntime()
        mockLLM.mockClient.nextResponse = "ok"

        let sink = CapturingLogSink()
        let logger = Logger(label: "test.facade.prompt-assembly") { _ in
            CapturingLogHandler(sink: sink)
        }

        _ = try await chat.run(ChatRunRequest(
            timelineId: timelineId,
            message: "Diagnose assembly",
            promptAssemblyLogger: logger
        )).collect()

        // PromptAssembler logs section resolution at .debug when a logger is supplied.
        #expect(sink.all().contains(where: { $0.contains("prompt section") }))
    }

    @Test
    func directFacadeInitializationSupportsOneTurnChat() async throws {
        let (chat, mockLLM, mockPersistence, timelineId, _) = try await makeAcceptanceRuntime()
        mockLLM.mockClient.nextResponse = "Hello, Morty!"

        let events = try await chat.run(ChatRunRequest(
            timelineId: timelineId,
            message: "Hello, Morty!"
        )).collect()

        #expect(events.contains(where: {
            if case let .completion(event: .generationCompleted(message, _)) = $0 {
                return message.content == "Hello, Morty!"
            }
            return false
        }))

        let messages = try await mockPersistence.fetchMessages(for: timelineId)
        #expect(messages.map(\.role) == ["user", "assistant"])
        #expect(messages.last?.content == "Hello, Morty!")
    }

    @Test
    func groupedPersistenceFacadeInitializationSupportsOneTurnChat() async throws {
        let (chat, mockLLM, mockPersistence, timelineId, _) = try await makeAcceptanceRuntime(useGroupedPersistence: true)
        mockLLM.mockClient.nextResponse = "Grouped persistence reply"

        let events = try await chat.run(ChatRunRequest(
            timelineId: timelineId,
            message: "Use grouped persistence"
        )).collect()

        #expect(events.contains(where: {
            if case let .completion(event: .generationCompleted(message, _)) = $0 {
                return message.content == "Grouped persistence reply"
            }
            return false
        }))

        let messages = try await mockPersistence.fetchMessages(for: timelineId)
        #expect(messages.count == 2)
        #expect(messages.last?.content == "Grouped persistence reply")
    }

    @Test
    func groupedRuntimeFacadeInitializationSupportsOneTurnChat() async throws {
        let (chat, mockLLM, mockPersistence, timelineId, _) = try await makeAcceptanceRuntime(useGroupedPersistence: true, useGroupedRuntime: true)
        mockLLM.mockClient.nextResponse = "Grouped runtime reply"

        let events = try await chat.run(ChatRunRequest(
            timelineId: timelineId,
            message: "Use grouped runtime"
        )).collect()

        #expect(events.contains(where: {
            if case let .completion(event: .generationCompleted(message, _)) = $0 {
                return message.content == "Grouped runtime reply"
            }
            return false
        }))

        let messages = try await mockPersistence.fetchMessages(for: timelineId)
        #expect(messages.last?.content == "Grouped runtime reply")
    }

    @Test
    func facadeToolCallTurnExecutesAndResumes() async throws {
        let (chat, mockLLM, _, timelineId, _) = try await makeAcceptanceRuntime()
        let mockTool = AcceptanceMockTool()

        mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool")]]
        mockLLM.mockClient.nextResponses = ["", "Tool result processed"]

        let events = try await chat.run(ChatRunRequest(
            timelineId: timelineId,
            message: "Run the tool",
            tools: [mockTool.toAnyTool()]
        )).collect()

        #expect(events.contains(where: {
            if case let .delta(event: .toolCall(delta)) = $0 {
                return delta.id == "call_1" && delta.name == "mock_tool"
            }
            return false
        }))
        #expect(events.contains(where: {
            if case let .completion(event: .toolExecution(id, status)) = $0,
               case let .success(result) = status
            {
                return id == "call_1" && result.output == "Tool result"
            }
            return false
        }))
        #expect(events.contains(where: {
            if case let .completion(event: .generationCompleted(message, _)) = $0 {
                return message.content == "Tool result processed"
            }
            return false
        }))
    }

    @Test
    func facadeToolOutputContinuationFlowPersistsSubmittedOutputs() async throws {
        let (chat, mockLLM, mockPersistence, timelineId, _) = try await makeAcceptanceRuntime()
        try await mockPersistence.saveMessage(ConversationMessage(
            timelineId: timelineId,
            role: .assistant,
            content: "",
            toolCalls: try pendingToolCallsJSON(ids: ["call_1"])
        ))
        mockLLM.mockClient.nextResponse = "Continuation complete"

        let events = try await chat.run(ChatRunRequest(
            timelineId: timelineId,
            message: "Continue",
            toolOutputs: [ToolOutputSubmission(toolCallId: "call_1", output: "Tool result")]
        )).collect()

        #expect(events.contains(where: {
            if case let .completion(event: .generationCompleted(message, _)) = $0 {
                return message.content == "Continuation complete"
            }
            return false
        }))

        let messages = try await mockPersistence.fetchMessages(for: timelineId)
        #expect(messages.map(\.role) == ["assistant", "tool", "user", "assistant"])
        #expect(messages.dropFirst().first?.toolCallId == "call_1")
        #expect(messages.dropFirst().first?.content == "Tool result")
    }

    @Test
    func facadeRejectsForgedToolOutputWithoutPendingCall() async throws {
        let (chat, _, mockPersistence, timelineId, _) = try await makeAcceptanceRuntime()

        await #expect(throws: ToolError.self) {
            _ = try await chat.run(ChatRunRequest(
                timelineId: timelineId,
                message: "Continue",
                toolOutputs: [ToolOutputSubmission(toolCallId: "forged_call", output: "forged output")]
            ))
        }

        let messages = try await mockPersistence.fetchMessages(for: timelineId)
        #expect(messages.isEmpty)
    }

    @Test
    func facadePluginFollowUpWorksWithoutDirectDependencyContainerSetup() async throws {
        let plugin = FacadeFollowUpPlugin()
        let (baseChat, mockLLM, mockPersistence, timelineId, _) = try await makeAcceptanceRuntime(useGroupedPersistence: true)
        let chat = baseChat.addPlugin(plugin)

        mockLLM.mockClient.nextResponses = ["First reply", "Second reply"]

        let events = try await chat.run(ChatRunRequest(
            timelineId: timelineId,
            message: "Start plugin flow"
        )).collect()

        let assistantReplies = events.compactMap(\.completedMessage).map(\.message.content)
        #expect(assistantReplies == ["First reply", "Second reply"])

        let persisted = try await mockPersistence.fetchMessages(for: timelineId)
        #expect(persisted.filter { $0.role == "assistant" }.map(\.content) == ["First reply", "Second reply"])
    }

    @Test
    func customPipelineStage() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()

        let timelineId = UUID()
        let message = "Hello, custom stage!"

        try await mockPersistence.saveTimeline(Timeline(id: timelineId, title: "Test"))

        let tracker = MockStageRunTracker()
        let customStage = MockCustomStage(tracker: tracker)

        let chat = makeChat(llmService: mockLLM, persistence: mockPersistence)
            .addStage(customStage)

        let stream = try await chat.run(ChatRunRequest(
            timelineId: timelineId,
            message: message
        ))

        for try await _ in stream {
            // Drain the stream; any thrown errors will propagate
        }

        let didRun = await tracker.didRun
        #expect(didRun, "Custom stage should have been executed")
    }

    @Test
    func runUsesTimelineContextManagerByDefault() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()

        mockLLM.mockClient.nextResponse = "Hello with context"

        let chat = PositronicKit(
            llmService: mockLLM,
            messageStore: mockPersistence,
            agentInstanceStore: mockPersistence,
            requestOriginStore: mockPersistence,
            timelinePersistence: mockPersistence,
            workspacePersistence: mockPersistence,
            memoryStore: mockPersistence,
            toolPersistence: mockPersistence,
            workspaceRoot: workspace.root,
            workspaceCreator: MockWorkspaceCreator()
        )
        let timeline = try await chat.timelineManager.createTimeline(title: "Context Enabled")

        let events = try await chat.run(ChatRunRequest(
            timelineId: timeline.id,
            message: "Use default context manager"
        )).collect()

        guard let generationContext = events.first(where: {
            if case .meta(event: .generationContext) = $0 { return true }
            return false
        }) else {
            Issue.record("Expected generationContext event")
            return
        }

        if case let .meta(event: .generationContext(metadata)) = generationContext {
            #expect(!metadata.files.isEmpty, "Timeline-managed Notes should be discovered by default")
        } else {
            Issue.record("First matching event was not generationContext")
        }
    }

    // MARK: - Helpers

    private func makeChat(
        llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient,
        persistence: MockPersistenceService
    ) -> PositronicKit {
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

    private func makeAcceptanceRuntime(
        useGroupedPersistence: Bool = false,
        useGroupedRuntime: Bool = false
    ) async throws -> (PositronicKit, MockLLMService, MockPersistenceService, UUID, TestWorkspace) {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()

        let chat: PositronicKit
        if useGroupedPersistence {
            let persistence = PositronicKit.PersistenceConfiguration(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )

            if useGroupedRuntime {
                chat = PositronicKit(
                    llmService: mockLLM,
                    persistence: persistence,
                    runtime: .init(
                        workspaceCreator: MockWorkspaceCreator(),
                        workspaceRoot: workspace.root
                    )
                )
            } else {
                chat = PositronicKit(
                    llmService: mockLLM,
                    persistence: persistence,
                    workspaceRoot: workspace.root
                )
            }
        } else {
            chat = PositronicKit(
                llmService: mockLLM,
                messageStore: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                workspaceRoot: workspace.root,
                workspaceCreator: MockWorkspaceCreator()
            )
        }

        let timelineManager = chat.timelineManager
        let timeline = try await timelineManager.createTimeline(title: "Acceptance")

        let workspaceId = UUID()
        let workspaceRef = WorkspaceReference(
            id: workspaceId,
            uri: WorkspaceURI(parsing: "pk://local")!,
            location: .runtimeTimeline,
            originId: nil,
            rootPath: workspace.root.path
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: timeline.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("mock_tool"))

        return (chat, mockLLM, mockPersistence, timeline.id, workspace)
    }

    private func pendingToolCallsJSON(ids: [String]) throws -> String {
        let calls = ids.map { ToolCall(id: $0, name: "external_tool", arguments: [:]) }
        let data = try SerializationUtils.jsonEncoder.encode(calls)
        return String(decoding: data, as: UTF8.self)
    }
}

private actor FacadeFollowUpPlugin: ChatTurnPlugin {
    private var hasInjectedFollowUp = false

    func afterTurn(_ turn: CompletedTurn) async throws -> [LLMMessage] {
        guard !hasInjectedFollowUp, turn.fullResponse == "First reply" else {
            return []
        }
        hasInjectedFollowUp = true
        return [LLMMessage(role: .user, content: "Plugin follow-up")]
    }
}

// MARK: - Test Helpers

private actor MockStageRunTracker {
    var didRun = false
    func setRun() {
        didRun = true
    }
}

private struct MockCustomStage: PipelineStage {
    let tracker: MockStageRunTracker
    var id: String {
        "MockCustomStage"
    }

    func process(_: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        await tracker.setRun()
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private struct AcceptanceMockTool: PKShared.Tool, @unchecked Sendable {
    let id = "mock_tool"
    let name = "mock_tool"
    let description = "Facade acceptance test tool"
    let requiresPermission = false
    let parametersSchema: [String: AnyCodable] = [:]

    func canExecute() async -> Bool {
        true
    }

    func execute(parameters _: [String: Any]) async throws -> ToolResult {
        .success("Tool result")
    }
}

// MARK: - Tool Argument Failure Mode Tests

extension PublicRuntimeStoriesTests {
    @Test("Tool with malformed JSON arguments emits error to LLM")
    func toolWithMalformedArguments() async throws {
        let (chat, mockLLM, mockPersistence, timelineId, _) = try await makeAcceptanceRuntime()
        mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool", arguments: "not valid json")]]
        mockLLM.mockClient.nextResponse = "Recovered after tool error"

        let events = try await chat.run(ChatRunRequest(
            timelineId: timelineId,
            message: "Call tool"
        )).collect()

        // Should have tool execution events (progress or completion)
        let toolEvent = events.first(where: {
            if case let .delta(event) = $0, case .toolExecution = event { return true }
            if case let .completion(event) = $0, case .toolExecution = event { return true }
            return false
        })
        #expect(toolEvent != nil)

        // Tool error should be persisted as a tool message
        let messages = try await mockPersistence.fetchMessages(for: timelineId)
        let toolMessage = messages.first(where: { $0.role == "tool" })
        #expect(toolMessage != nil)
        #expect(toolMessage?.content.contains("Error") == true)
    }

    @Test("Tool execution failure returns error to LLM for recovery")
    func toolExecutionFailure() async throws {
        let (chat, mockLLM, mockPersistence, timelineId, _) = try await makeAcceptanceRuntime()
        // Mock tool returns success by default - we'll simulate failure via the mock client
        // by having the tool call produce an error response
        mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "nonexistent_tool", arguments: "{}")]]
        mockLLM.mockClient.nextResponse = "Recovered after tool error"

        let events = try await chat.run(ChatRunRequest(
            timelineId: timelineId,
            message: "Call nonexistent tool"
        )).collect()

        // Should have tool completed with failure status
        let toolErrorEvent = events.first(where: {
            if case let .completion(event) = $0, case let .toolExecution(_, status) = event {
                if case .failed = status { return true }
            }
            return false
        })
        #expect(toolErrorEvent != nil)

        // Error message should be persisted
        let persistedMessages = try await mockPersistence.fetchMessages(for: timelineId)
        let toolMessage = persistedMessages.first(where: { $0.role == "tool" })
        #expect(toolMessage?.content.contains("Error") == true)
    }
}
