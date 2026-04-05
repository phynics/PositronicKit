import Dependencies
import Foundation
@testable import MonadCore
@testable import MonadShared
import MonadTestSupport
import OpenAI
import Testing

@Suite @MainActor
struct ChatEngineTests {
    private let timelineId = UUID()

    /// Helper to run a test with standard dependencies
    private func withChatEngineDependencies<T>(_ test: @Sendable (ChatEngine, MockLLMService, MockPersistenceService) async throws -> T) async throws -> T {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()

        // Seed a session
        let session = Timeline(id: timelineId, title: "Test Session")
        try await mockPersistence.saveTimeline(session)

        return try await withDependencies {
            $0.llmService = mockLLM
            $0.timelinePersistence = mockPersistence
            $0.workspacePersistence = mockPersistence
            $0.memoryStore = mockPersistence
            $0.messageStore = mockPersistence
            $0.agentTemplateStore = mockPersistence
            $0.clientStore = mockPersistence
            $0.toolPersistence = mockPersistence
            $0.agentInstanceStore = mockPersistence
            $0.timelineManager = TimelineManager(workspaceRoot: URL(fileURLWithPath: "/tmp/monad-test"), workspaceCreator: MockWorkspaceCreator())
            $0.toolRouter = ToolRouter()
        } operation: {
            @Dependency(\.timelineManager) var timelineManager
            let wsId = UUID()
            let workspaceRef = WorkspaceReference(id: wsId, uri: WorkspaceURI(parsing: "monad://local")!, hostType: .serverTimeline, ownerId: nil, rootPath: "/tmp")
            try await mockPersistence.saveWorkspace(workspaceRef)
            try await timelineManager.attachWorkspace(wsId, to: timelineId)
            try await mockPersistence.addToolToWorkspace(workspaceId: wsId, tool: .known("mock_tool"))

            let engine = ChatEngine()

            try await timelineManager.hydrateTimeline(id: timelineId)

            if let toolManager = await timelineManager.getToolManager(for: timelineId) {
                var tools = await toolManager.getAvailableTools()
                tools.append(MockTool().toAnyTool())
                await toolManager.updateAvailableTools(tools)

                if let ws = try? await timelineManager.workspaceManager.getWorkspace(id: wsId) {
                    await toolManager.registerWorkspace(ws)
                }
            }

            return try await test(engine, mockLLM, mockPersistence)
        }
    }

    /// Helper to collect events from a stream
    private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: - Group 1: Plain Text Response

    @Test("Plain text response emits correct events")
    func plainTextResponse() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextResponse = "Hello, world!"

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Hi",
                tools: []
            )

            let events = try await collect(stream)

            // Should have meta.generationContext, delta.generation, and completion.generationCompleted
            #expect(events.contains(where: { if case .meta(event: .generationContext) = $0 { return true }; return false }))
            #expect(events.contains(where: { if case let .delta(event: .generation(text: text)) = $0 { return text == "Hello, world!" }; return false }))
            #expect(events.contains(where: { if case .completion(event: .generationCompleted) = $0 { return true }; return false }))
        }
    }

    @Test("Response is persisted to the database")
    func responseIsPersisted() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            mockLLM.mockClient.nextResponse = "Persisted reply."

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Persistence test",
                tools: []
            )

            _ = try await collect(stream)

            let messages = try await mockPersistence.fetchMessages(for: timelineId)

            // Should contain user message and assistant reply
            #expect(messages.count == 2)
            #expect(messages.contains(where: { $0.role == "user" && $0.content == "Persistence test" }))
            #expect(messages.contains(where: { $0.role == "assistant" && $0.content == "Persisted reply." }))
        }
    }

    @Test("Empty message and no tool outputs throws error")
    func emptyMessageThrows() async throws {
        _ = try await withChatEngineDependencies { engine, _, _ in
            await #expect(throws: ChatEngineError.self) {
                _ = try await engine.execute(
                    timelineId: timelineId,
                    message: "",
                    tools: []
                )
            }
        }
    }

    // MARK: - Group 2: Thinking / Reasoning Tags

    @Test("Thinking tags emit thought events")
    func thinkingTagsEmitThoughtEvents() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextChunks = [["<think>", "Reasoning...", "</think>", "Answer"]]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Why?",
                tools: []
            )

            let events = try await collect(stream)

            var foundThinking = false
            var foundGeneration = false

            for event in events {
                if let text = event.thinkingContent {
                    if text == "Reasoning..." { foundThinking = true }
                } else if let text = event.textContent {
                    if text == "Answer" { foundGeneration = true }
                }
            }

            #expect(foundThinking)
            #expect(foundGeneration)
        }
    }

    // MARK: - Group 3: Structured Tool Calls

    struct MockTool: MonadShared.Tool, @unchecked Sendable {
        let id = "mock_tool"
        let name = "mock_tool"
        let description = "A mock tool for testing"
        let requiresPermission = false
        let parametersSchema: [String: AnyCodable] = [:]

        var result: ToolResult = .success("Tool result")
        var shouldWait: Bool = false

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: Any]) async throws -> ToolResult {
            if shouldWait { try? await Task.sleep(nanoseconds: 100_000_000) }
            if !result.success && result.error == "client_tools_disallowed_on_private_timeline" {
                throw ToolError.clientToolsDisallowedOnPrivateTimeline
            }
            return result
        }
    }

    @Test("Server-side tool call is executed and yields events")
    func serverToolCallExecuted() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()

            // Set up responses for both turns at once
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool")]]
            mockLLM.mockClient.nextResponses = ["", "Processed result"]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Run tool",
                tools: [mockTool.toAnyTool()]
            )

            let events = try await collect(stream)

            // Should see toolCall delta
            #expect(events.contains(where: { if case let .delta(event: .toolCall(delta: delta)) = $0 { return delta.name == "mock_tool" }; return false }))

            // Should see tool execution attempting (delta)
            #expect(events.contains(where: {
                if case let .delta(event: .toolExecution(id, status)) = $0 {
                    if case .attempting = status { return id == "call_1" }
                }
                return false
            }))
            // Should see tool execution success (completion)
            #expect(events.contains(where: {
                if case let .completion(event: .toolExecution(id, status)) = $0 {
                    if case let .success(result) = status { return id == "call_1" && result.output == "Tool result" }
                }
                return false
            }))

            // Final response
            #expect(events.contains(where: { if case let .delta(event: .generation(text: text)) = $0 { return text == "Processed result" }; return false }))
        }
    }

    @Test("Sentinel name 'tool_call' is discarded")
    func sentinelToolNameDiscarded() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            // Emit "tool_call" name which is a sentinel for some models
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "tool_call")]]
            mockLLM.mockClient.nextResponses = ["Ignored tool name"]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Run sentinel",
                tools: [MockTool().toAnyTool()]
            )

            let events = try await collect(stream)

            // Should NOT have completion.toolExecution events for "tool_call"
            #expect(!events.contains(where: { if case .completion(event: .toolExecution) = $0 { return true }; return false }))
            // Should just see the plain text delta
            #expect(events.contains(where: { if case let .delta(event: .generation(text: text)) = $0 { return text == "Ignored tool name" }; return false }))
        }
    }

    @Test("Unknown tool name emits toolCallError")
    func unknownToolNameEmitsError() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "unknown_tool")]]
            mockLLM.mockClient.nextResponses = ["", "Unknown tool call"]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Run unknown",
                tools: [MockTool().toAnyTool()]
            )

            let events = try await collect(stream)

            // Should see toolCall delta
            #expect(events.contains(where: { if case let .delta(event: .toolCall(delta: delta)) = $0 { return delta.name == "unknown_tool" }; return false }))

            // Should have toolExecution failure
            #expect(events.contains(where: {
                if case let .completion(event: .toolExecution(id, status)) = $0 {
                    if case .failed = status { return id == "call_1" }
                }
                return false
            }))

            #expect(events.contains(where: { if case let .delta(event: .generation(text: text)) = $0 { return text == "Unknown tool call" }; return false }))
        }
    }

    @Test("Client tool execution pauses the stream")
    func clientToolCallPausesStream() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            var mockTool = MockTool()
            mockTool.result = .failure("client_tools_disallowed_on_private_timeline")

            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool")]]
            mockLLM.mockClient.nextResponses = ["Pause here"]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Run client tool",
                tools: [mockTool.toAnyTool()]
            )

            let events = try await collect(stream)

            // Should emit attempt (delta) but NOT success/failure (handled by client)
            #expect(events.contains(where: {
                if case let .delta(event: .toolExecution(id, status)) = $0 {
                    if case .attempting = status { return id == "call_1" }
                }
                return false
            }))

            // Should NOT have completion.toolExecution success or failure since engine stops
            #expect(!events.contains(where: {
                if case .completion(event: .toolExecution(_, let status)) = $0 {
                    switch status {
                    case .success, .failure: return true
                    default: return false
                    }
                }
                return false
            }))

            // Should reach generationCompleted
            #expect(events.contains(where: { if case .completion(event: .generationCompleted) = $0 { return true }; return false }))
        }
    }

    @Test("Failing tool returns error result to LLM")
    func failingToolReturnsErrorResult() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            var mockTool = MockTool()
            mockTool.result = .failure("Tool failed")

            // Set up responses for both turns
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool")]]
            mockLLM.mockClient.nextResponses = ["", "It failed."]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Fail tool",
                tools: [mockTool.toAnyTool()]
            )

            let events = try await collect(stream)

            #expect(events.contains(where: {
                if case let .completion(event: .toolExecution(id, status)) = $0 {
                    if case .failed = status { return id == "call_1" }
                }
                return false
            }))

            #expect(events.contains(where: { if case let .delta(event: .generation(text: text)) = $0 { return text == "It failed." }; return false }))
        }
    }

    // MARK: - Group 4: Fallback XML Parsing

    @Test("XML fallback tool call is executed")
    func xmlFallbackToolCallExecuted() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()

            // Set up responses for both turns
            mockLLM.mockClient.nextResponses = [
                "<tool_call>{\"name\":\"mock_tool\",\"arguments\":{}}</tool_call>",
                "Fallback worked"
            ]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Run XML tool",
                tools: [mockTool.toAnyTool()]
            )

            let events = try await collect(stream)

            // Fallback should yield a .delta(.toolCall) event for UI
            #expect(events.contains(where: { if case let .delta(event: .toolCall(delta: delta)) = $0 { return delta.name == "mock_tool" }; return false }))

            // Should see tool execution completion
            #expect(events.contains(where: {
                if case .completion(event: .toolExecution(_, let status)) = $0 {
                    if case let .success(result) = status { return result.output == "Tool result" }
                }
                return false
            }))

            #expect(events.contains(where: { if case let .delta(event: .generation(text: text)) = $0 { return text == "Fallback worked" }; return false }))
        }
    }

    // MARK: - Group 5: Multi-Turn & Loop Control

    @Test("maxTurns limits the generation loop")
    func maxTurnsLimitsLoop() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()
            // Setup a loop: LLM calls tool, tool returns result, LLM calls tool again...
            mockLLM.mockClient.nextToolCalls = [
                [MockToolCall(id: "c1", name: "mock_tool")],
                [MockToolCall(id: "c2", name: "mock_tool")],
                [MockToolCall(id: "c3", name: "mock_tool")]
            ]
            mockLLM.mockClient.nextResponses = ["", "", ""]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Infinite tools",
                tools: [mockTool.toAnyTool()],
                maxTurns: 2 // Limit to 2 turns
            )

            let events = try await collect(stream)

            // Should have executed exactly 2 tools (id c1 and c2)
            let successEvents = events.filter {
                if case .completion(event: .toolExecution(_, let status)) = $0, case .success = status { return true }
                return false
            }
            #expect(successEvents.count == 2)

            // maxTurns exhausted while tool calls were pending — no generationCompleted is emitted.
            // Verify the stream finished cleanly (no thrown error — collect would throw if it did).
            let completionCount = events.filter {
                if case .completion(event: .generationCompleted) = $0 { return true }
                return false
            }.count
            #expect(completionCount == 0)
        }
    }

    @Test("LLM service errors are propagated through the stream")
    func llmErrorPropagated() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.shouldThrowError = true

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Trigger error",
                tools: []
            )

            await #expect(throws: (any Error).self) {
                for try await _ in stream {}
            }
        }
    }

    // MARK: - Group 6: Metadata & Context Events

    @Test("Generation context event is emitted first")
    func generationContextEventEmittedFirst() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextResponse = "Hello"

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Hi",
                tools: []
            )

            var firstEvent: ChatEvent?
            for try await event in stream {
                firstEvent = event
                break
            }

            if let first = firstEvent {
                if case .meta(event: .generationContext) = first {
                    // Success
                } else {
                    #expect(Bool(false), "First event should be meta.generationContext, got \(first)")
                }
            } else {
                #expect(Bool(false), "Stream was empty")
            }
        }
    }

    // MARK: - Group 7: Tool Output Resume

    @Test("Tool outputs are persisted before user message")
    func toolOutputsPersistedBeforeUserMessage() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            mockLLM.mockClient.nextResponse = "Continuing."

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Next question",
                tools: [],
                toolOutputs: [ToolOutputSubmission(toolCallId: "prev_call", output: "tool result")]
            )

            _ = try await collect(stream)

            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            // tool output → user message → assistant message
            #expect(messages.count == 3)
            #expect(messages[0].role == "tool")
            #expect(messages[1].role == "user")
            #expect(messages[2].role == "assistant")
        }
    }

    @Test("Empty message with tool outputs is valid")
    func emptyMessageWithToolOutputsIsValid() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            mockLLM.mockClient.nextResponse = "Reply."

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "",
                tools: [],
                toolOutputs: [ToolOutputSubmission(toolCallId: "c1", output: "output")]
            )

            _ = try await collect(stream)

            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            #expect(messages.contains(where: { $0.role == "tool" && $0.toolCallId == "c1" }))
            #expect(!messages.contains(where: { $0.role == "user" }))
        }
    }

    // MARK: - Group 8: Configuration

    @Test("LLM service not configured throws executionFailed")
    func llmNotConfiguredThrows() async throws {
        _ = try await withChatEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockIsConfigured = false
            await #expect(throws: ChatEngineError.self) {
                _ = try await engine.execute(
                    timelineId: timelineId,
                    message: "Hello",
                    tools: []
                )
            }
        }
    }

    // MARK: - Group 9: Multiple Tool Calls Per Turn

    @Test("Multiple tool calls in one turn are all executed")
    func multipleToolCallsExecuted() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()
            mockLLM.mockClient.nextToolCalls = [[
                MockToolCall(id: "c1", name: "mock_tool"),
                MockToolCall(id: "c2", name: "mock_tool")
            ]]
            mockLLM.mockClient.nextResponses = ["", "Both done"]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Run two tools",
                tools: [mockTool.toAnyTool()]
            )

            let events = try await collect(stream)

            let successIds = events.compactMap { event -> String? in
                if case let .completion(event: .toolExecution(id, status)) = event,
                   case .success = status { return id }
                return nil
            }
            #expect(successIds.contains("c1"))
            #expect(successIds.contains("c2"))
            #expect(successIds.count == 2)
        }
    }

    // MARK: - Group 10: Event Invariants

    @Test("Exactly one generationCompleted event for plain text response")
    func exactlyOneGenerationCompletedForPlainText() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextResponse = "Done"

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Hi",
                tools: []
            )

            let events = try await collect(stream)
            let count = events.filter { if case .completion(event: .generationCompleted) = $0 { return true }; return false }.count
            #expect(count == 1)
        }
    }

    @Test("Emits generationCompleted event per turn after multi-turn tool execution")
    func generationCompletedPerTurnAfterMultiTurn() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "c1", name: "mock_tool")]]
            mockLLM.mockClient.nextResponses = ["", "Final answer"]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Use tool",
                tools: [mockTool.toAnyTool()]
            )

            let events = try await collect(stream)
            // Turn 1 had pending tool calls — no generationCompleted emitted.
            // Turn 2 was a clean text response — exactly one generationCompleted emitted.
            let count = events.filter { if case .completion(event: .generationCompleted) = $0 { return true }; return false }.count
            #expect(count == 1)
        }
    }

    // MARK: - Group 11: Agent Instance

    @Test("agentInstanceId is recorded on the persisted assistant message")
    func agentInstanceIdSetOnMessage() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            let agentId = UUID()
            let agentInstance = AgentInstance(
                id: agentId,
                name: "Test Agent",
                description: "Testing",
                privateTimelineId: UUID()
            )
            try await mockPersistence.saveAgentInstance(agentInstance)
            mockLLM.mockClient.nextResponse = "Agent reply"

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Hi agent",
                tools: [],
                agentInstanceId: agentId
            )

            _ = try await collect(stream)

            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            let assistantMsg = messages.first { $0.role == "assistant" }
            #expect(assistantMsg?.agentInstanceId == agentId)
        }
    }
}
