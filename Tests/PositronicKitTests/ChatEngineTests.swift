import Foundation
import OpenAI
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite(.serialized) @MainActor
struct ChatEngineTests {
    private let timelineId = UUID()

    /// Helper to run a test with standard dependencies
    private func withChatEngineDependencies<T>(
        streamTimeout: TimeInterval = 60,
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
                chatTurnPlugins: [],
                streamTimeout: streamTimeout
            )
        )

        // Seed a session
        let session = Timeline(id: timelineId, title: "Test Session")
        try await mockPersistence.saveTimeline(session)

        let wsId = UUID()
        let workspaceRef = WorkspaceReference(id: wsId, uri: WorkspaceURI(parsing: "pk://local")!, location: .runtimeTimeline, originId: nil, rootPath: "/tmp")
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(wsId, to: timelineId)
        try await mockPersistence.addToolToWorkspace(workspaceId: wsId, tool: .known("mock_tool"))

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

    struct MockTool: PKShared.Tool, @unchecked Sendable {
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
                throw ToolError.attachedToolsDisallowedOnPrivateTimeline
            }
            return result
        }
    }

    @Test("Runtime tool call is executed and yields events")
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

    @Test("Provider stream timeout surfaces on tool follow-up")
    func providerStreamTimeoutSurfacesOnToolFollowUp() async throws {
        try await withChatEngineDependencies(streamTimeout: 0.05) { engine, mockLLM, _ in
            let mockTool = MockTool()
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool")]]
            mockLLM.mockClient.nextResponses = [""]
            mockLLM.mockClient.neverFinishingStreamCallIndices = [2]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Run tool then hang",
                tools: [mockTool.toAnyTool()]
            )

            var sawToolSuccess = false
            do {
                for try await event in stream {
                    if case let .completion(event: .toolExecution(id, status)) = event,
                       id == "call_1",
                       case .success = status
                    {
                        sawToolSuccess = true
                    }
                }
                Issue.record("Expected the follow-up provider stream to time out")
            } catch let PipelineError.stageFailed(id, underlyingError) {
                #expect(id == "LLMStreamingStage")
                guard case let ChatEngineError.streamTimedOut(timeout) = underlyingError else {
                    Issue.record("Expected streamTimedOut, got \(underlyingError)")
                    return
                }
                #expect(timeout == 0.05)
            } catch {
                Issue.record("Expected PipelineError.stageFailed, got \(error)")
            }
            #expect(sawToolSuccess)
        }
    }

    @Test("Never-ending first-turn stream also surfaces stream timeout")
    func providerStreamTimeoutSurfacesOnFirstTurn() async throws {
        try await withChatEngineDependencies(streamTimeout: 0.05) { engine, mockLLM, _ in
            mockLLM.mockClient.neverFinishingStreamCallIndices = [1]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Hang immediately",
                tools: []
            )

            do {
                for try await _ in stream {}
                Issue.record("Expected the first turn stream to time out")
            } catch let PipelineError.stageFailed(id, underlyingError) {
                #expect(id == "LLMStreamingStage")
                guard case let ChatEngineError.streamTimedOut(timeout) = underlyingError else {
                    Issue.record("Expected streamTimedOut, got \(underlyingError)")
                    return
                }
                #expect(timeout == 0.05)
            } catch {
                Issue.record("Expected PipelineError.stageFailed, got \(error)")
            }
        }
    }

    @Test("A slow but steadily-progressing stream is not killed by the idle timeout")
    func slowProgressingStreamSurvivesIdleTimeout() async throws {
        // Idle (inactivity) timeout of 0.3s. The stream delivers 5 chunks ~0.1s apart, so the
        // total streaming time (~0.5s) exceeds the timeout, but no single gap does. A *total*
        // wall-clock cap would throw mid-stream; an idle timeout must let it finish.
        try await withChatEngineDependencies(streamTimeout: 0.3) { engine, mockLLM, _ in
            mockLLM.mockClient.nextChunks = [["Hel", "lo ", "wor", "ld", "!"]]
            mockLLM.mockClient.nextStreamWait = 0.1

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "stream slowly",
                tools: []
            )

            // A throw here (e.g. streamTimedOut) would fail the test; draining must complete.
            var sawGeneration = false
            for try await event in stream {
                if case .delta(event: .generation) = event { sawGeneration = true }
            }
            #expect(sawGeneration)
        }
    }

    @Test("Empty completed response emits an explicit empty-completion signal")
    func emptyCompletedResponseEmitsDistinctSignal() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextResponse = ""

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Return nothing",
                tools: []
            )

            let events = try await collect(stream)

            #expect(events.contains(where: {
                if case let .completion(event: .generationCompleted(message, metadata)) = $0 {
                    return message.content.isEmpty && metadata.finishReason == "stop"
                }
                return false
            }))
            #expect(events.contains(where: {
                if case let .completion(event: .completedEmpty(finishReason)) = $0 {
                    return finishReason == "stop"
                }
                return false
            }))
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

    @Test("Deferred attached-workspace tool execution pauses the stream")
    func deferredExternalToolCallPausesStream() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            var mockTool = MockTool()
            mockTool.result = .failure("client_tools_disallowed_on_private_timeline")

            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool")]]
            mockLLM.mockClient.nextResponses = ["Pause here"]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Run attached tool",
                tools: [mockTool.toAnyTool()]
            )

            let events = try await collect(stream)

            // Should emit attempt (delta) but NOT success/failure because execution is deferred.
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
                "Fallback worked",
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

    @Test("Fragmented native tool-call chunks execute end-to-end without assistant text in the first turn")
    func fragmentedNativeToolCallExecutesWithoutAssistantText() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()

            mockLLM.mockClient.nextRawStreamChunks = [[
                LLMStreamChunk(
                    id: "mock-1",
                    model: "mock-model",
                    choices: [LLMStreamChoice(
                        index: 0,
                        delta: LLMStreamDelta(
                            role: .assistant,
                            content: nil,
                            toolCalls: [
                                LLMToolCallDelta(
                                    index: 0,
                                    id: "call_frag",
                                    function: LLMToolCallDeltaFunction(name: "mock_", arguments: "{")
                                ),
                            ]
                        ),
                        finishReason: nil
                    )]
                ),
                LLMStreamChunk(
                    id: "mock-2",
                    model: "mock-model",
                    choices: [LLMStreamChoice(
                        index: 0,
                        delta: LLMStreamDelta(
                            role: .assistant,
                            content: nil,
                            toolCalls: [
                                LLMToolCallDelta(
                                    index: 0,
                                    id: nil,
                                    function: LLMToolCallDeltaFunction(name: "tool", arguments: "}")
                                ),
                            ]
                        ),
                        finishReason: "tool_calls"
                    )]
                ),
            ]]
            mockLLM.mockClient.nextResponses = ["Processed fragmented tool"]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Run fragmented tool",
                tools: [mockTool.toAnyTool()]
            )

            let events = try await collect(stream)

            #expect(events.contains(where: {
                if case let .delta(event: .toolCall(delta)) = $0 {
                    return delta.id == "call_frag"
                }
                return false
            }))
            #expect(events.contains(where: {
                if case let .completion(event: .toolExecution(id, status)) = $0,
                   case let .success(result) = status
                {
                    return id == "call_frag" && result.output == "Tool result"
                }
                return false
            }))
            #expect(events.contains(where: {
                if case let .delta(event: .generation(text)) = $0 {
                    return text == "Processed fragmented tool"
                }
                return false
            }))

            let completedCount = events.filter {
                if case .completion(event: .generationCompleted) = $0 { return true }
                return false
            }.count
            #expect(completedCount == 1)
        }
    }

    @Test("Recovered tool-call chunk resumes tool execution after finish_reason-only stream chunk")
    func recoveredToolCallChunkExecutesAfterFinishReasonOnlyChunk() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()

            mockLLM.mockClient.nextRawStreamChunks = [[
                LLMStreamChunk(
                    id: "mock-1",
                    model: "mock-model",
                    choices: [LLMStreamChoice(
                        index: 0,
                        delta: LLMStreamDelta(role: .assistant, content: "Checking tool availability..."),
                        finishReason: nil
                    )]
                ),
                LLMStreamChunk(
                    id: "mock-2",
                    model: "mock-model",
                    choices: [LLMStreamChoice(
                        index: 0,
                        delta: LLMStreamDelta(role: .assistant, content: nil, toolCalls: nil),
                        finishReason: "tool_calls"
                    )]
                ),
                LLMStreamChunk(
                    id: "mock-3",
                    model: "mock-model",
                    choices: [LLMStreamChoice(
                        index: 0,
                        delta: LLMStreamDelta(
                            role: .assistant,
                            content: nil,
                            toolCalls: [
                                LLMToolCallDelta(
                                    index: 0,
                                    id: "call_recovered",
                                    function: LLMToolCallDeltaFunction(name: "mock_tool", arguments: "{}")
                                ),
                            ]
                        ),
                        finishReason: "tool_calls"
                    )]
                ),
            ]]
            mockLLM.mockClient.nextResponses = ["Recovered tool handled"]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Recover omitted tool call",
                tools: [mockTool.toAnyTool()]
            )

            let events = try await collect(stream)

            let toolCallIndices = events.enumerated().compactMap { index, event -> Int? in
                if case let .delta(event: .toolCall(delta)) = event, delta.id == "call_recovered" {
                    return index
                }
                return nil
            }
            #expect(toolCallIndices.count == 1)

            let toolCompletionIndex = events.enumerated().first { _, event in
                if case let .completion(event: .toolExecution(id, status)) = event,
                   case let .success(result) = status
                {
                    return id == "call_recovered" && result.output == "Tool result"
                }
                return false
            }?.offset
            let generationCompletedIndex = events.enumerated().first { _, event in
                if case .completion(event: .generationCompleted) = event { return true }
                return false
            }?.offset

            let toolCallIndex = try #require(toolCallIndices.first)
            let completedToolIndex = try #require(toolCompletionIndex)
            let finalCompletionIndex = try #require(generationCompletedIndex)

            #expect(toolCallIndex < completedToolIndex)
            #expect(completedToolIndex < finalCompletionIndex)
            #expect(events.contains(where: {
                if case let .delta(event: .generation(text)) = $0 {
                    return text == "Recovered tool handled"
                }
                return false
            }))
        }
    }

    @Test("finish_reason tool_calls without recovered deltas does not invent a tool execution")
    func finishReasonOnlyChunkDoesNotInventToolExecution() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            let mockTool = MockTool()

            mockLLM.mockClient.nextRawStreamChunks = [[
                LLMStreamChunk(
                    id: "mock-1",
                    model: "mock-model",
                    choices: [LLMStreamChoice(
                        index: 0,
                        delta: LLMStreamDelta(role: .assistant, content: nil, toolCalls: nil),
                        finishReason: "tool_calls"
                    )]
                ),
            ]]

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "No recovered tool call",
                tools: [mockTool.toAnyTool()]
            )

            let events = try await collect(stream)

            #expect(!events.contains(where: {
                if case .completion(event: .toolExecution) = $0 { return true }
                return false
            }))
            #expect(events.contains(where: {
                if case .completion(event: .generationCompleted) = $0 { return true }
                return false
            }))

            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            let assistantMessages = messages.filter { $0.role == "assistant" }
            #expect(assistantMessages.count == 1)
            #expect(assistantMessages[0].toolCalls == "[]")
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
                [MockToolCall(id: "c3", name: "mock_tool")],
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
                if firstEvent == nil {
                    firstEvent = event
                }
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

    @Test("Unmatched tool outputs are rejected and not persisted")
    func unmatchedToolOutputsAreRejectedAndNotPersisted() async throws {
        try await withChatEngineDependencies { engine, _, mockPersistence in
            await #expect(throws: ToolError.self) {
                _ = try await engine.execute(
                    timelineId: timelineId,
                    message: "Next question",
                    tools: [],
                    toolOutputs: [ToolOutputSubmission(toolCallId: "forged_call", output: "tool result")]
                )
            }

            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            #expect(messages.isEmpty)
        }
    }

    @Test("Duplicate tool output submissions for the same pending call are rejected")
    func duplicateToolOutputSubmissionsAreRejected() async throws {
        try await withChatEngineDependencies { engine, _, mockPersistence in
            try await mockPersistence.saveMessage(ConversationMessage(
                timelineId: timelineId,
                role: .assistant,
                content: "",
                toolCalls: try pendingToolCallsJSON(ids: ["call_1"])
            ))

            await #expect(throws: ToolError.self) {
                _ = try await engine.execute(
                    timelineId: timelineId,
                    message: "",
                    tools: [],
                    toolOutputs: [
                        ToolOutputSubmission(toolCallId: "call_1", output: "first"),
                        ToolOutputSubmission(toolCallId: "call_1", output: "duplicate"),
                    ]
                )
            }

            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            #expect(messages.filter { $0.role == "tool" }.isEmpty)
        }
    }

    @Test("Concurrent submissions for one pending tool call consume it only once")
    func concurrentToolOutputSubmissionsConsumePendingCallOnce() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            try await mockPersistence.saveMessage(ConversationMessage(
                timelineId: timelineId,
                role: .assistant,
                content: "",
                toolCalls: try pendingToolCallsJSON(ids: ["call_race"])
            ))
            mockLLM.mockClient.nextResponses = ["first continuation", "second continuation"]

            let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for index in 0 ..< 2 {
                    group.addTask {
                        do {
                            let stream = try await engine.execute(
                                timelineId: timelineId,
                                message: "",
                                tools: [],
                                toolOutputs: [
                                    ToolOutputSubmission(
                                        toolCallId: "call_race",
                                        output: "tool result \(index)"
                                    ),
                                ]
                            )
                            _ = try await collect(stream)
                            return true
                        } catch ToolError.unmatchedToolOutput {
                            return false
                        } catch {
                            Issue.record("Unexpected error: \(error)")
                            return false
                        }
                    }
                }

                var values: [Bool] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }

            #expect(results.filter(\.self).count == 1)
            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            let toolMessages = messages.filter { $0.role == "tool" && $0.toolCallId == "call_race" }
            #expect(toolMessages.count == 1)
        }
    }

    @Test("Stale dangling assistant tool calls are not accepted after later history")
    func staleDanglingAssistantToolCallsAreRejected() async throws {
        try await withChatEngineDependencies { engine, _, mockPersistence in
            try await mockPersistence.saveMessage(ConversationMessage(
                timelineId: timelineId,
                role: .assistant,
                content: "",
                timestamp: Date(timeIntervalSince1970: 100),
                toolCalls: try pendingToolCallsJSON(ids: ["stale_call"])
            ))
            try await mockPersistence.saveMessage(ConversationMessage(
                timelineId: timelineId,
                role: .user,
                content: "later user message",
                timestamp: Date(timeIntervalSince1970: 200)
            ))

            await #expect(throws: ToolError.self) {
                _ = try await engine.execute(
                    timelineId: timelineId,
                    message: "",
                    tools: [],
                    toolOutputs: [ToolOutputSubmission(toolCallId: "stale_call", output: "stale result")]
                )
            }

            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            #expect(messages.filter { $0.role == "tool" }.isEmpty)
        }
    }

    @Test("Dangling assistant tool calls fail before provider request")
    func danglingAssistantToolCallFailsBeforeProviderRequest() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            try await mockPersistence.saveMessage(ConversationMessage(
                timelineId: timelineId,
                role: .assistant,
                content: "",
                toolCalls: try pendingToolCallsJSON(ids: ["dangling_call"])
            ))

            do {
                _ = try await engine.execute(
                    timelineId: timelineId,
                    message: "Follow up",
                    tools: [MockTool().toAnyTool()]
                )
                Issue.record("Expected dangling tool call error")
            } catch let error as ChatEngineError {
                #expect(error.userFriendlyMessage.contains("assistant tool call"))
                #expect(error.userFriendlyMessage.contains("matching tool result"))
            } catch {
                Issue.record("Expected ChatEngineError, got \(error)")
            }

            #expect(mockLLM.mockClient.streamCallCount == 0)
        }
    }

    @Test("Well-formed tool history preserves provider ids across reloads")
    func wellFormedToolHistoryPreservesProviderIdsAcrossReloads() async throws {
        let persistence = MockPersistenceService()
        let mockLLM = MockLLMService()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspaceCreator: MockWorkspaceCreator()
        )
        let toolRouter = ToolRouter(
            timelineManager: timelineManager,
            messageStore: persistence
        )
        let engine = ChatEngine(
            dependencies: .init(
                timelineManager: timelineManager,
                agentInstanceStore: persistence,
                requestOriginStore: persistence,
                messageStore: persistence,
                llmService: mockLLM,
                toolRouter: toolRouter,
                chatTurnPlugins: [],
                streamTimeout: 60
            )
        )

        let timelineId = UUID()
        let session = Timeline(id: timelineId, title: "Reload Session")
        try await persistence.saveTimeline(session)

        let wsId = UUID()
        let workspaceRef = WorkspaceReference(
            id: wsId,
            uri: WorkspaceURI(parsing: "pk://local")!,
            location: .runtimeTimeline,
            originId: nil,
            rootPath: "/tmp"
        )
        try await persistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(wsId, to: timelineId)
        try await persistence.addToolToWorkspace(workspaceId: wsId, tool: .known("mock_tool"))
        try await timelineManager.hydrateTimeline(id: timelineId)

        if let toolManager = await timelineManager.getToolManager(for: timelineId) {
            var tools = await toolManager.getAvailableTools()
            tools.append(MockTool().toAnyTool())
            await toolManager.updateAvailableTools(tools)

            if let ws = try? await timelineManager.workspaceManager.getWorkspace(id: wsId) {
                await toolManager.registerWorkspace(ws)
            }
        }

        try await persistence.saveMessage(ConversationMessage(
            timelineId: timelineId,
            role: .assistant,
            content: "",
            toolCalls: try pendingToolCallsJSON(ids: ["provider_call"])
        ))
        try await persistence.saveMessage(ConversationMessage(
            timelineId: timelineId,
            role: .tool,
            content: "Tool result",
            toolCallId: "provider_call"
        ))

        mockLLM.mockClient.nextResponse = "First reply"
        _ = try await collect(try await engine.execute(
            timelineId: timelineId,
            message: "First follow up",
            tools: []
        ))

        let firstReloadPromptPreservedProviderID = mockLLM.mockClient.messageHistory.first?.contains(where: { message in
            message.role == .assistant && message.toolCalls?.first?.id == "provider_call"
        }) == true
        #expect(firstReloadPromptPreservedProviderID)
        #expect(mockLLM.mockClient.streamCallCount == 1)

        let storedMessages = try await persistence.fetchMessages(for: timelineId)
        let storedAssistantPreservedProviderID = storedMessages.contains(where: { message in
            let reconstructed = message.toMessage()
            return reconstructed.role == .assistant && reconstructed.toolCalls?.contains(where: { $0.id == "provider_call" }) == true
        })
        #expect(storedAssistantPreservedProviderID)

        let reloadLLM = MockLLMService()
        let reloadEngine = ChatEngine(
            dependencies: .init(
                timelineManager: timelineManager,
                agentInstanceStore: persistence,
                requestOriginStore: persistence,
                messageStore: persistence,
                llmService: reloadLLM,
                toolRouter: toolRouter,
                chatTurnPlugins: [],
                streamTimeout: 60
            )
        )

        reloadLLM.mockClient.nextResponse = "Second reply"
        _ = try await collect(try await reloadEngine.execute(
            timelineId: timelineId,
            message: "Second follow up",
            tools: []
        ))

        let secondReloadPromptPreservedProviderID = reloadLLM.mockClient.messageHistory.first?.contains(where: { message in
            message.role == .assistant && message.toolCalls?.first?.id == "provider_call"
        }) == true
        #expect(secondReloadPromptPreservedProviderID)
        #expect(reloadLLM.mockClient.streamCallCount == 1)
    }

    @Test("Tool outputs matching pending assistant calls are persisted before user message")
    func matchedToolOutputsPersistedBeforeUserMessage() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            try await mockPersistence.saveMessage(ConversationMessage(
                timelineId: timelineId,
                role: .assistant,
                content: "",
                toolCalls: try pendingToolCallsJSON(ids: ["prev_call"])
            ))
            mockLLM.mockClient.nextResponse = "Continuing."

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "Next question",
                tools: [],
                toolOutputs: [ToolOutputSubmission(toolCallId: "prev_call", output: "tool result")]
            )

            _ = try await collect(stream)

            let messages = try await mockPersistence.fetchMessages(for: timelineId)
            // pending assistant → tool output → user message → assistant message
            #expect(messages.count == 4)
            #expect(messages[0].role == "assistant")
            #expect(messages[1].role == "tool")
            #expect(messages[2].role == "user")
            #expect(messages[3].role == "assistant")
        }
    }

    @Test("Empty message with tool outputs is valid")
    func emptyMessageWithToolOutputsIsValid() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            try await mockPersistence.saveMessage(ConversationMessage(
                timelineId: timelineId,
                role: .assistant,
                content: "",
                toolCalls: try pendingToolCallsJSON(ids: ["c1"])
            ))
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

    private func pendingToolCallsJSON(ids: [String]) throws -> String {
        let calls = ids.map { ToolCall(id: $0, name: "external_tool", arguments: [:]) }
        let data = try SerializationUtils.jsonEncoder.encode(calls)
        return String(decoding: data, as: UTF8.self)
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

    @Test("Production chat engine wiring uses a bounded stream timeout by default")
    func productionChatEngineUsesBoundedStreamTimeout() {
        let dependencies = ChatEngine.Dependencies(
            timelineManager: TimelineManager(
                stores: .init(
                    timelineStore: MockPersistenceService(),
                    messageStore: MockPersistenceService(),
                    workspaceStore: MockPersistenceService(),
                    toolPersistence: MockPersistenceService()
                ),
                workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
                workspaceCreator: MockWorkspaceCreator()
            ),
            agentInstanceStore: MockPersistenceService(),
            requestOriginStore: MockPersistenceService(),
            messageStore: MockPersistenceService(),
            llmService: MockLLMService(),
            toolRouter: ToolRouter(
                timelineManager: TimelineManager(
                    stores: .init(
                        timelineStore: MockPersistenceService(),
                        messageStore: MockPersistenceService(),
                        workspaceStore: MockPersistenceService(),
                        toolPersistence: MockPersistenceService()
                    ),
                    workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
                    workspaceCreator: MockWorkspaceCreator()
                ),
                messageStore: MockPersistenceService()
            ),
            chatTurnPlugins: []
        )

        #expect(dependencies.streamTimeout == ChatEngine.Dependencies.defaultStreamTimeout)
        #expect(dependencies.streamTimeout > 0)
    }

    // MARK: - Group 9: Multiple Tool Calls Per Turn

    @Test("Multiple tool calls in one turn are all executed")
    func multipleToolCallsExecuted() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()
            mockLLM.mockClient.nextToolCalls = [[
                MockToolCall(id: "c1", name: "mock_tool"),
                MockToolCall(id: "c2", name: "mock_tool"),
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
