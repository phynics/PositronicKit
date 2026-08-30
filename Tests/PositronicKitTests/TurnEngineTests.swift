import Foundation
import OpenAI
@testable import PKContracts
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Testing

@Suite(.serialized) @MainActor
struct TurnEngineTests {
    private let threadID = UUID()

    /// Helper to run a test with standard dependencies
    private func withTurnEngineDependencies<T>(
        streamTimeout: TimeInterval = 60,
        attachedAgentID: UUID? = nil,
        _ test: @Sendable (TurnEngine, MockLLMService, MockPersistenceService) async throws -> T
    ) async throws -> T {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                runtimeRepository: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceProfile: .hostManaged(root: URL(fileURLWithPath: "/tmp/pk-test")),
            workspaceCreator: MockWorkspaceCreator()
        )
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            runtimeRepository: mockPersistence
        )
        let engine = TurnEngine(
            dependencies: .init(
                threadManager: threadManager,
                agentStore: mockPersistence,
                requestOriginStore: mockPersistence,
                runtimeRepository: mockPersistence,
                llmService: mockLLM,
                toolRouter: toolRouter,
                streamTimeout: streamTimeout
            )
        )

        // Seed a session
        let session = Thread(
            id: threadID,
            title: "Test Session",
            attachedAgentID: attachedAgentID
        )
        try await mockPersistence.saveThread(session)

        let wsId = UUID()
        let workspaceRef = WorkspaceReference(id: wsId, uri: WorkspaceURI(parsing: "pk://local")!, location: .runtimeThread, originID: nil, rootPath: "/tmp")
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(wsId, to: threadID)
        try await mockPersistence.addToolToWorkspace(workspaceId: wsId, tool: .known("mock_tool"))

        try await threadManager.hydrateThread(id: threadID)

        if let toolManager = await threadManager.getToolManager(for: threadID) {
            var tools = await toolManager.getAvailableTools()
            tools.append(MockTool().toAnyTool())
            await toolManager.updateAvailableTools(tools)

            if let ws = try? await threadManager.workspaceResolver.workspace(id: wsId) {
                await toolManager.registerWorkspace(ws)
            }
        }

        return try await test(engine, mockLLM, mockPersistence)
    }

    /// Helper to collect events from a stream
    private func collect(_ stream: AsyncThrowingStream<TurnEvent, Error>) async throws -> [TurnEvent] {
        var events: [TurnEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private nonisolated func generationDeltas(_ events: [TurnEvent]) -> [String] {
        events.compactMap { event in
            if case let .delta(.generation(text: text)) = event { return text }
            return nil
        }
    }

    // MARK: - Group 1: Plain Text Response

    @Test("Plain text response emits correct events")
    func plainTextResponse() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextResponse = "Hello, world!"

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Hi",
                    tools: []
                )
            ))

            let events = try await collect(stream)

            // Should have delta.generation and completion.generationCompleted
            #expect(events.contains(where: { if case let .delta(.generation(text: text)) = $0 { return text == "Hello, world!" }; return false }))
            #expect(events.contains(where: { if case .completion(.generationCompleted) = $0 { return true }; return false }))
        }
    }

    @Test("Response is persisted to the database")
    func responseIsPersisted() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, mockPersistence in
            mockLLM.mockClient.nextResponse = "Persisted reply."

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Persistence test",
                    tools: []
                )
            ))

            _ = try await collect(stream)

            let messages = try await mockPersistence.fetchMessages(for: threadID)

            // Should contain user message and assistant reply
            #expect(messages.count == 2)
            #expect(messages.contains(where: { $0.role == "user" && $0.content == "Persistence test" }))
            #expect(messages.contains(where: { $0.role == "assistant" && $0.content == "Persisted reply." }))
        }
    }

    @Test("Empty message and no tool outputs throws error")
    func emptyMessageThrows() async throws {
        _ = try await withTurnEngineDependencies { engine, _, _ in
            await #expect(throws: TurnEngineError.self) {
                _ = try await engine.execute(TurnExecutionRequest(
                    TurnRequest(
                        threadID: threadID,
                        message: "",
                        tools: []
                    )
                ))
            }
        }
    }

    @Test("Unsupported media fails before persistence or provider calls")
    func unsupportedMediaFailsBeforeSideEffects() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, mockPersistence in
            let content = MessageContent(parts: [
                .image(ImageContent(data: Data([0x01]), mediaType: "image/png")),
            ])

            await #expect(throws: MultimodalContentError.self) {
                _ = try await engine.execute(TurnExecutionRequest(
                    TurnRequest(
                        threadID: threadID,
                        content: content,
                        tools: []
                    )
                ))
            }

            #expect(mockLLM.mockClient.streamCallCount == 0)
            let persisted = try await mockPersistence.fetchMessages(for: threadID)
            #expect(persisted.isEmpty)
        }
    }

    @Test("Audio deltas assemble byte-for-byte and persist with their transcript")
    func streamedAudioPersistsCompletedContent() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, mockPersistence in
            var configuration = mockLLM.mockConfig
            configuration.providers[.openAI]?.capabilities = [.audioOutput]
            mockLLM.mockConfig = configuration
            mockLLM.mockClient.nextRawStreamChunks = [[
                LLMStreamChunk(
                    id: "audio-1",
                    model: "mock",
                    choices: [LLMStreamChoice(
                        index: 0,
                        delta: LLMStreamDelta(audio: LLMAudioDelta(
                            data: Data([0x01, 0x02]),
                            format: .wav,
                            transcript: "hel"
                        )),
                        finishReason: nil
                    )]
                ),
                LLMStreamChunk(
                    id: "audio-1",
                    model: "mock",
                    choices: [LLMStreamChoice(
                        index: 0,
                        delta: LLMStreamDelta(audio: LLMAudioDelta(
                            data: Data([0x03, 0x04]),
                            format: .wav,
                            transcript: "lo"
                        )),
                        finishReason: "stop"
                    )]
                ),
            ]]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    content: MessageContent("speak"),
                    tools: [],
                    responseModalities: [.text, .audio],
                    audioOutput: AudioOutputOptions(format: .wav, voice: "alloy")
                )
            ))
            let events = try await collect(stream)

            #expect(events.compactMap(\.audioDelta).map(\.data) == [Data([0x01, 0x02]), Data([0x03, 0x04])])
            #expect(events.compactMap(\.textContent).joined() == "hello")

            let messages = try await mockPersistence.fetchMessages(for: threadID)
            let assistant = try #require(messages.last(where: { $0.role == "assistant" }))
            #expect(assistant.content == "hello")
            let audio = assistant.messageContent.parts.compactMap { part -> AudioContent? in
                guard case let .audio(value) = part else { return nil }
                return value
            }.first
            #expect(audio?.data == Data([0x01, 0x02, 0x03, 0x04]))
            #expect(audio?.transcript == "hello")
        }
    }

    @Test("Completed audio without a transcript fails and preserves partial bytes")
    func completedAudioWithoutTranscriptIsProviderContractError() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, mockPersistence in
            var configuration = mockLLM.mockConfig
            configuration.providers[.openAI]?.capabilities = [.audioOutput]
            mockLLM.mockConfig = configuration
            mockLLM.mockClient.nextRawStreamChunks = [[
                LLMStreamChunk(
                    id: "audio-no-transcript",
                    model: "mock",
                    choices: [LLMStreamChoice(
                        index: 0,
                        delta: LLMStreamDelta(audio: LLMAudioDelta(
                            data: Data([0x0A, 0x0B]),
                            format: .wav
                        )),
                        finishReason: "stop"
                    )]
                ),
            ]]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    content: MessageContent("speak without transcript"),
                    tools: [],
                    responseModalities: [.audio],
                    audioOutput: AudioOutputOptions(format: .wav, voice: "alloy")
                )
            ))
            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            let messages = try await mockPersistence.fetchMessages(for: threadID)
            let assistant = try #require(messages.last(where: { $0.role == "assistant" }))
            #expect(assistant.status == .partial)
            let audio = assistant.messageContent.parts.compactMap { part -> AudioContent? in
                guard case let .audio(value) = part else { return nil }
                return value
            }.first
            #expect(audio?.data == Data([0x0A, 0x0B]))
            #expect(audio?.transcript == nil)
        }
    }

    // MARK: - Group 2: Thinking / Reasoning Tags

    @Test("Thinking tags emit thought events")
    func thinkingTagsEmitThoughtEvents() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextChunks = [["<think>", "Reasoning...", "</think>", "Answer"]]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Why?",
                    tools: []
                )
            ))

            let events = try await collect(stream)

            var foundThinking = false
            var foundGeneration = false

            for event in events {
                if let text = event.reasoningContent {
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

    struct MockTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName = "mock_tool"
        let name = "mock_tool"
        let description = "A mock tool for testing"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        var result: ToolResult = .success("Tool result")
        var shouldWait: Bool = false

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            if shouldWait { try? await Task.sleep(nanoseconds: 100_000_000) }
            if !result.success && result.error == "client_tools_disallowed_on_private_thread" {
                throw ToolError.attachedToolsDisallowedOnPrivateThread
            }
            return result
        }
    }

    @Test("Runtime tool call is executed and yields events")
    func serverToolCallExecuted() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()

            // Set up responses for both turns at once
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool")]]
            mockLLM.mockClient.nextResponses = ["", "Processed result"]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Run tool",
                    tools: [mockTool.toAnyTool()]
                )
            ))

            let events = try await collect(stream)

            // Should see toolCall delta
            #expect(events.contains(where: { if case let .delta(.toolCall(delta: delta)) = $0 { return delta.name == "mock_tool" }; return false }))

            // Should see tool execution attempting (delta)
            #expect(events.contains(where: {
                if case let .delta(.toolExecution(id, status)) = $0 {
                    if case .attempting = status { return id == "call_1" }
                }
                return false
            }))
            // Should see tool execution success (completion)
            #expect(events.contains(where: {
                if case let .completion(.toolExecution(id, status)) = $0 {
                    if case let .success(result) = status { return id == "call_1" && result.output == "Tool result" }
                }
                return false
            }))

            // Final response
            #expect(events.contains(where: { if case let .delta(.generation(text: text)) = $0 { return text == "Processed result" }; return false }))
        }
    }

    @Test("Provider stream timeout surfaces on tool follow-up")
    func providerStreamTimeoutSurfacesOnToolFollowUp() async throws {
        try await withTurnEngineDependencies(streamTimeout: 0.05) { engine, mockLLM, _ in
            let mockTool = MockTool()
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool")]]
            mockLLM.mockClient.nextResponses = [""]
            mockLLM.mockClient.neverFinishingStreamCallIndices = [2]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Run tool then hang",
                    tools: [mockTool.toAnyTool()]
                )
            ))

            var sawToolSuccess = false
            do {
                for try await event in stream {
                    if case let .completion(.toolExecution(id, status)) = event,
                       id == "call_1",
                       case .success = status
                    {
                        sawToolSuccess = true
                    }
                }
                Issue.record("Expected the follow-up provider stream to time out")
            } catch let PipelineError.stageFailed(id, underlyingError) {
                #expect(id == "LLMStreamingStage")
                guard case let TurnEngineError.streamTimedOut(timeout) = underlyingError else {
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
        try await withTurnEngineDependencies(streamTimeout: 0.05) { engine, mockLLM, _ in
            mockLLM.mockClient.neverFinishingStreamCallIndices = [1]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Hang immediately",
                    tools: []
                )
            ))

            do {
                for try await _ in stream {}
                Issue.record("Expected the first turn stream to time out")
            } catch let PipelineError.stageFailed(id, underlyingError) {
                #expect(id == "LLMStreamingStage")
                guard case let TurnEngineError.streamTimedOut(timeout) = underlyingError else {
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
        try await withTurnEngineDependencies(streamTimeout: 0.3) { engine, mockLLM, _ in
            mockLLM.mockClient.nextChunks = [["Hel", "lo ", "wor", "ld", "!"]]
            mockLLM.mockClient.nextStreamWait = 0.1

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "stream slowly",
                    tools: []
                )
            ))

            // A throw here (e.g. streamTimedOut) would fail the test; draining must complete.
            var sawGeneration = false
            for try await event in stream {
                if case .delta(.generation) = event { sawGeneration = true }
            }
            #expect(sawGeneration)
        }
    }

    @Test("Empty completed response emits an explicit empty-completion signal")
    func emptyCompletedResponseEmitsDistinctSignal() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextResponse = ""

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Return nothing",
                    tools: []
                )
            ))

            let events = try await collect(stream)

            #expect(events.contains(where: {
                if case let .completion(.generationCompleted(message, metadata)) = $0 {
                    return message.content.isEmpty && metadata.finishReason == "stop"
                }
                return false
            }))
            #expect(events.filter(\.isTerminal).count == 1)
        }
    }

    @Test("Sentinel name 'tool_call' is discarded")
    func sentinelToolNameDiscarded() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            // Emit "tool_call" name which is a sentinel for some models
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "tool_call")]]
            mockLLM.mockClient.nextResponses = ["Ignored tool name"]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Run sentinel",
                    tools: [MockTool().toAnyTool()]
                )
            ))

            let events = try await collect(stream)

            // Should NOT have completion.toolExecution events for "tool_call"
            #expect(!events.contains(where: { if case .completion(.toolExecution) = $0 { return true }; return false }))
            // Should just see the plain text delta
            #expect(events.contains(where: { if case let .delta(.generation(text: text)) = $0 { return text == "Ignored tool name" }; return false }))
        }
    }

    @Test("Unknown tool name emits toolCallError")
    func unknownToolNameEmitsError() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "unknown_tool")]]
            mockLLM.mockClient.nextResponses = ["", "Unknown tool call"]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Run unknown",
                    tools: [MockTool().toAnyTool()]
                )
            ))

            let events = try await collect(stream)

            // Should see toolCall delta
            #expect(events.contains(where: { if case let .delta(.toolCall(delta: delta)) = $0 { return delta.name == "unknown_tool" }; return false }))

            // Should have toolExecution failure
            #expect(events.contains(where: {
                if case let .completion(.toolExecution(id, status)) = $0 {
                    if case .failed = status { return id == "call_1" }
                }
                return false
            }))

            #expect(events.contains(where: { if case let .delta(.generation(text: text)) = $0 { return text == "Unknown tool call" }; return false }))
        }
    }

    @Test("Deferred attached-workspace tool execution pauses the stream")
    func deferredExternalToolCallPausesStream() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            var mockTool = MockTool()
            mockTool.result = .failure("client_tools_disallowed_on_private_thread")

            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool")]]
            mockLLM.mockClient.nextResponses = ["Pause here"]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Run attached tool",
                    tools: [mockTool.toAnyTool()]
                )
            ))

            let events = try await collect(stream)

            // Should emit attempt (delta) but NOT success/failure because execution is deferred.
            #expect(events.contains(where: {
                if case let .delta(.toolExecution(id, status)) = $0 {
                    if case .attempting = status { return id == "call_1" }
                }
                return false
            }))

            // Should NOT have completion.toolExecution success or failure since engine stops
            #expect(!events.contains(where: {
                if case let .completion(.toolExecution(_, status)) = $0 {
                    switch status {
                    case .success, .executionError: return true
                    default: return false
                    }
                }
                return false
            }))

            // Should reach generationCompleted
            #expect(events.contains(where: { if case .completion(.generationCompleted) = $0 { return true }; return false }))
        }
    }

    @Test("Failing tool returns error result to LLM")
    func failingToolReturnsErrorResult() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            var mockTool = MockTool()
            mockTool.result = .failure("Tool failed")

            // Set up responses for both turns
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool")]]
            mockLLM.mockClient.nextResponses = ["", "It failed."]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Fail tool",
                    tools: [mockTool.toAnyTool()]
                )
            ))

            let events = try await collect(stream)

            #expect(events.contains(where: {
                if case let .completion(.toolExecution(id, status)) = $0 {
                    if case .failed = status { return id == "call_1" }
                }
                return false
            }))

            #expect(events.contains(where: { if case let .delta(.generation(text: text)) = $0 { return text == "It failed." }; return false }))
        }
    }

    // MARK: - Group 4: Raw-text tool calls (no longer parsed)

    @Test("XML tool-call text is not executed as a tool call")
    func xmlFallbackToolCallExecuted() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()

            mockLLM.mockClient.nextResponses = [
                "Fallback worked",
            ]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Run XML tool",
                    tools: [mockTool.toAnyTool()]
                )
            ))

            let events = try await collect(stream)

            #expect(!events.contains(where: { if case let .delta(.toolCall(delta: delta)) = $0 { return delta.name == "mock_tool" }; return false }))

            #expect(!events.contains(where: {
                if case let .completion(.toolExecution(_, status)) = $0 {
                    if case .success = status { return true }
                }
                return false
            }))
        }
    }

    @Test("Fragmented native tool-call chunks execute end-to-end without assistant text in the first turn")
    func fragmentedNativeToolCallExecutesWithoutAssistantText() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
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

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Run fragmented tool",
                    tools: [mockTool.toAnyTool()]
                )
            ))

            let events = try await collect(stream)

            #expect(events.contains(where: {
                if case let .delta(.toolCall(delta)) = $0 {
                    return delta.id == "call_frag"
                }
                return false
            }))
            #expect(events.contains(where: {
                if case let .completion(.toolExecution(id, status)) = $0,
                   case let .success(result) = status
                {
                    return id == "call_frag" && result.output == "Tool result"
                }
                return false
            }))
            #expect(events.contains(where: {
                if case let .delta(.generation(text)) = $0 {
                    return text == "Processed fragmented tool"
                }
                return false
            }))

            let completedCount = events.filter {
                if case .completion(.generationCompleted) = $0 { return true }
                return false
            }.count
            #expect(completedCount == 1)
        }
    }

    @Test("Recovered tool-call chunk resumes tool execution after finish_reason-only stream chunk")
    func recoveredToolCallChunkExecutesAfterFinishReasonOnlyChunk() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
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

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Recover omitted tool call",
                    tools: [mockTool.toAnyTool()]
                )
            ))

            let events = try await collect(stream)

            let toolCallIndices = events.enumerated().compactMap { index, event -> Int? in
                if case let .delta(.toolCall(delta)) = event, delta.id == "call_recovered" {
                    return index
                }
                return nil
            }
            #expect(toolCallIndices.count == 1)

            let toolCompletionIndex = events.enumerated().first { _, event in
                if case let .completion(.toolExecution(id, status)) = event,
                   case let .success(result) = status
                {
                    return id == "call_recovered" && result.output == "Tool result"
                }
                return false
            }?.offset
            let generationCompletedIndex = events.enumerated().first { _, event in
                if case .completion(.generationCompleted) = event { return true }
                return false
            }?.offset

            let toolCallIndex = try #require(toolCallIndices.first)
            let completedToolIndex = try #require(toolCompletionIndex)
            let finalCompletionIndex = try #require(generationCompletedIndex)

            #expect(toolCallIndex < completedToolIndex)
            #expect(completedToolIndex < finalCompletionIndex)
            #expect(events.contains(where: {
                if case let .delta(.generation(text)) = $0 {
                    return text == "Recovered tool handled"
                }
                return false
            }))
        }
    }

    @Test("finish_reason tool_calls without recovered deltas does not invent a tool execution")
    func finishReasonOnlyChunkDoesNotInventToolExecution() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, mockPersistence in
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

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "No recovered tool call",
                    tools: [mockTool.toAnyTool()]
                )
            ))

            let events = try await collect(stream)

            #expect(!events.contains(where: {
                if case .completion(.toolExecution) = $0 { return true }
                return false
            }))
            #expect(events.contains(where: {
                if case .completion(.generationCompleted) = $0 { return true }
                return false
            }))

            let messages = try await mockPersistence.fetchMessages(for: threadID)
            let assistantMessages = messages.filter { $0.role == "assistant" }
            #expect(assistantMessages.count == 1)
            #expect(assistantMessages[0].toolCalls == "[]")
        }
    }

    // MARK: - Group 5: Multi-Turn & Loop Control

    @Test("maxModelRounds limits the generation loop")
    func maxModelRoundsLimitsLoop() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()
            // Setup a loop: LLM calls tool, tool returns result, LLM calls tool again...
            mockLLM.mockClient.nextToolCalls = [
                [MockToolCall(id: "c1", name: "mock_tool")],
                [MockToolCall(id: "c2", name: "mock_tool")],
                [MockToolCall(id: "c3", name: "mock_tool")],
            ]
            mockLLM.mockClient.nextResponses = ["", "", ""]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Infinite tools",
                    tools: [mockTool.toAnyTool()],
                    maxModelRounds: 2 // Limit to 2 turns
                )
            ))

            let events = try await collect(stream)

            // Should have executed exactly 2 tools (id c1 and c2)
            let successEvents = events.filter {
                if case let .completion(.toolExecution(_, status)) = $0, case .success = status { return true }
                return false
            }
            #expect(successEvents.count == 2)

            // Model-round exhaustion emits a distinct terminal event (PKRR-011). Previously the
            // stream finished silently with no terminal signal, making exhaustion look like a
            // success with no generationCompleted. Now it emits exactly one `.maxModelRoundsReached`.
            let maxModelRoundsEvents = events.filter {
                if case .completion(.maxModelRoundsReached) = $0 { return true }
                return false
            }
            #expect(maxModelRoundsEvents.count == 1)

            // The distinct terminal event replaces `.generationCompleted` — no normal completion
            // is emitted when the loop exhausts its turn budget mid-tool.
            let completionCount = events.filter {
                if case .completion(.generationCompleted) = $0 { return true }
                return false
            }.count
            #expect(completionCount == 0)
        }
    }

    @Test("LLM service errors are propagated through the stream")
    func llmErrorPropagated() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.shouldThrowError = true

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Trigger error",
                    tools: []
                )
            ))

            await #expect(throws: (any Error).self) {
                for try await _ in stream {}
            }
        }
    }

    // MARK: - Group 7: Tool Output Resume

    @Test("Unmatched tool outputs are rejected and not persisted")
    func unmatchedToolOutputsAreRejectedAndNotPersisted() async throws {
        try await withTurnEngineDependencies { engine, _, mockPersistence in
            await #expect(throws: ToolError.self) {
                _ = try await engine.execute(TurnExecutionRequest(
                    TurnRequest(
                        threadID: threadID,
                        message: "Next question",
                        tools: [],
                        toolOutputs: [ToolOutputSubmission(toolCallID: "forged_call", output: "tool result")]
                    )
                ))
            }

            let messages = try await mockPersistence.fetchMessages(for: threadID)
            #expect(messages.filter { $0.role == "tool" }.isEmpty)
        }
    }

    @Test("Duplicate tool output submissions for the same pending call are rejected")
    func duplicateToolOutputSubmissionsAreRejected() async throws {
        try await withTurnEngineDependencies { engine, _, mockPersistence in
            try await mockPersistence.saveMessage(ThreadMessage(
                threadID: threadID,
                role: .assistant,
                content: "",
                toolCalls: pendingToolCallsJSON(ids: ["call_1"])
            ))

            await #expect(throws: ToolError.self) {
                _ = try await engine.execute(TurnExecutionRequest(
                    TurnRequest(
                        threadID: threadID,
                        message: "",
                        tools: [],
                        toolOutputs: [
                            ToolOutputSubmission(toolCallID: "call_1", output: "first"),
                            ToolOutputSubmission(toolCallID: "call_1", output: "duplicate"),
                        ]
                    )
                ))
            }

            let messages = try await mockPersistence.fetchMessages(for: threadID)
            #expect(messages.filter { $0.role == "tool" }.isEmpty)
        }
    }

    @Test("Concurrent submissions for one pending tool call consume it only once")
    func concurrentToolOutputSubmissionsConsumePendingCallOnce() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, mockPersistence in
            try await mockPersistence.saveMessage(ThreadMessage(
                threadID: threadID,
                role: .assistant,
                content: "",
                toolCalls: pendingToolCallsJSON(ids: ["call_race"])
            ))
            mockLLM.mockClient.nextResponses = ["first continuation", "second continuation"]

            let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for index in 0 ..< 2 {
                    group.addTask {
                        do {
                            let stream = try await engine.execute(TurnExecutionRequest(
                                TurnRequest(
                                    threadID: threadID,
                                    message: "",
                                    tools: [],
                                    toolOutputs: [
                                        ToolOutputSubmission(
                                            toolCallID: "call_race",
                                            output: "tool result \(index)"
                                        ),
                                    ]
                                )
                            ))
                            _ = try await collect(stream)
                            return true
                        } catch ToolError.unmatchedToolOutput {
                            return false
                        } catch ThreadRuntimeRepositoryError.threadBusy {
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
            let messages = try await mockPersistence.fetchMessages(for: threadID)
            let toolMessages = messages.filter { $0.role == "tool" && $0.toolCallID == "call_race" }
            #expect(toolMessages.count == 1)
        }
    }

    @Test("Stale dangling assistant tool calls are not accepted after later history")
    func staleDanglingAssistantToolCallsAreRejected() async throws {
        try await withTurnEngineDependencies { engine, _, mockPersistence in
            try await mockPersistence.saveMessage(ThreadMessage(
                threadID: threadID,
                role: .assistant,
                content: "",
                timestamp: Date(timeIntervalSince1970: 100),
                toolCalls: pendingToolCallsJSON(ids: ["stale_call"])
            ))
            try await mockPersistence.saveMessage(ThreadMessage(
                threadID: threadID,
                role: .user,
                content: "later user message",
                timestamp: Date(timeIntervalSince1970: 200)
            ))

            await #expect(throws: ToolError.self) {
                _ = try await engine.execute(TurnExecutionRequest(
                    TurnRequest(
                        threadID: threadID,
                        message: "",
                        tools: [],
                        toolOutputs: [ToolOutputSubmission(toolCallID: "stale_call", output: "stale result")]
                    )
                ))
            }

            let messages = try await mockPersistence.fetchMessages(for: threadID)
            #expect(messages.filter { $0.role == "tool" }.isEmpty)
        }
    }

    @Test("Dangling assistant tool calls fail before provider request")
    func danglingAssistantToolCallFailsBeforeProviderRequest() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, mockPersistence in
            try await mockPersistence.saveMessage(ThreadMessage(
                threadID: threadID,
                role: .assistant,
                content: "",
                toolCalls: pendingToolCallsJSON(ids: ["dangling_call"])
            ))

            do {
                _ = try await engine.execute(TurnExecutionRequest(
                    TurnRequest(
                        threadID: threadID,
                        message: "Follow up",
                        tools: [MockTool().toAnyTool()]
                    )
                ))
                Issue.record("Expected dangling tool call error")
            } catch let error as TurnEngineError {
                #expect(error.userFriendlyMessage.contains("assistant tool call"))
                #expect(error.userFriendlyMessage.contains("matching tool result"))
            } catch {
                Issue.record("Expected TurnEngineError, got \(error)")
            }

            #expect(mockLLM.mockClient.streamCallCount == 0)
        }
    }

    @Test("Well-formed tool history preserves provider ids across reloads")
    func wellFormedToolHistoryPreservesProviderIdsAcrossReloads() async throws {
        let persistence = MockPersistenceService()
        let mockLLM = MockLLMService()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .hostManaged(root: URL(fileURLWithPath: "/tmp/pk-test")),
            workspaceCreator: MockWorkspaceCreator()
        )
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            runtimeRepository: persistence
        )
        let engine = TurnEngine(
            dependencies: .init(
                threadManager: threadManager,
                agentStore: persistence,
                requestOriginStore: persistence,
                runtimeRepository: persistence,
                llmService: mockLLM,
                toolRouter: toolRouter,
                streamTimeout: 60
            )
        )

        let threadID = UUID()
        let session = Thread(id: threadID, title: "Reload Session")
        try await persistence.saveThread(session)

        let wsId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: wsId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtimeThread,
            originID: nil,
            rootPath: "/tmp"
        )
        try await persistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(wsId, to: threadID)
        try await persistence.addToolToWorkspace(workspaceId: wsId, tool: .known("mock_tool"))
        try await threadManager.hydrateThread(id: threadID)

        if let toolManager = await threadManager.getToolManager(for: threadID) {
            var tools = await toolManager.getAvailableTools()
            tools.append(MockTool().toAnyTool())
            await toolManager.updateAvailableTools(tools)

            if let ws = try? await threadManager.workspaceResolver.workspace(id: wsId) {
                await toolManager.registerWorkspace(ws)
            }
        }

        try await persistence.saveMessage(ThreadMessage(
            threadID: threadID,
            role: .assistant,
            content: "",
            toolCalls: pendingToolCallsJSON(ids: ["provider_call"])
        ))
        try await persistence.saveMessage(ThreadMessage(
            threadID: threadID,
            role: .tool,
            content: "Tool result",
            toolCallID: "provider_call"
        ))

        mockLLM.mockClient.nextResponse = "First reply"
        _ = try await collect(await engine.execute(TurnExecutionRequest(
            TurnRequest(
                threadID: threadID,
                message: "First follow up",
                tools: []
            )
        )))

        let firstReloadPromptPreservedProviderID = mockLLM.mockClient.messageHistory.first?.contains(where: { message in
            message.role == .assistant && message.toolCalls?.first?.id == "provider_call"
        }) == true
        #expect(firstReloadPromptPreservedProviderID)
        #expect(mockLLM.mockClient.streamCallCount == 1)

        let storedMessages = try await persistence.fetchMessages(for: threadID)
        let storedAssistantPreservedProviderID = storedMessages.contains(where: { message in
            let reconstructed = message.toMessage()
            return reconstructed.role == .assistant && reconstructed.toolCalls?.contains(where: { $0.id == "provider_call" }) == true
        })
        #expect(storedAssistantPreservedProviderID)

        let reloadLLM = MockLLMService()
        let reloadEngine = TurnEngine(
            dependencies: .init(
                threadManager: threadManager,
                agentStore: persistence,
                requestOriginStore: persistence,
                runtimeRepository: persistence,
                llmService: reloadLLM,
                toolRouter: toolRouter,
                streamTimeout: 60
            )
        )

        reloadLLM.mockClient.nextResponse = "Second reply"
        _ = try await collect(await reloadEngine.execute(TurnExecutionRequest(
            TurnRequest(
                threadID: threadID,
                message: "Second follow up",
                tools: []
            )
        )))

        let secondReloadPromptPreservedProviderID = reloadLLM.mockClient.messageHistory.first?.contains(where: { message in
            message.role == .assistant && message.toolCalls?.first?.id == "provider_call"
        }) == true
        #expect(secondReloadPromptPreservedProviderID)
        #expect(reloadLLM.mockClient.streamCallCount == 1)
    }

    @Test("Tool outputs matching pending assistant calls remain durable with the admitted user message")
    func matchedToolOutputsPersistedBeforeUserMessage() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, mockPersistence in
            try await mockPersistence.saveMessage(ThreadMessage(
                threadID: threadID,
                role: .assistant,
                content: "",
                toolCalls: pendingToolCallsJSON(ids: ["prev_call"])
            ))
            mockLLM.mockClient.nextResponse = "Continuing."

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Next question",
                    tools: [],
                    toolOutputs: [ToolOutputSubmission(toolCallID: "prev_call", output: "tool result")]
                )
            ))

            _ = try await collect(stream)

            let messages = try await mockPersistence.fetchMessages(for: threadID)
            // Admission durably records the user before preparation commits tool outputs.
            // The sequence is therefore pending assistant → user message → tool output → assistant.
            #expect(messages.count == 4)
            #expect(messages[0].role == "assistant")
            #expect(messages[1].role == "user")
            #expect(messages[2].role == "tool")
            #expect(messages[3].role == "assistant")
        }
    }

    @Test("Empty message with tool outputs is valid")
    func emptyMessageWithToolOutputsIsValid() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, mockPersistence in
            try await mockPersistence.saveMessage(ThreadMessage(
                threadID: threadID,
                role: .assistant,
                content: "",
                toolCalls: pendingToolCallsJSON(ids: ["c1"])
            ))
            mockLLM.mockClient.nextResponse = "Reply."

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "",
                    tools: [],
                    toolOutputs: [ToolOutputSubmission(toolCallID: "c1", output: "output")]
                )
            ))

            _ = try await collect(stream)

            let messages = try await mockPersistence.fetchMessages(for: threadID)
            #expect(messages.contains(where: { $0.role == "tool" && $0.toolCallID == "c1" }))
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
        _ = try await withTurnEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockIsConfigured = false
            await #expect(throws: TurnEngineError.self) {
                _ = try await engine.execute(TurnExecutionRequest(
                    TurnRequest(
                        threadID: threadID,
                        message: "Hello",
                        tools: []
                    )
                ))
            }
        }
    }

    @Test("Production turn engine wiring uses a bounded stream timeout by default")
    func productionTurnEngineUsesBoundedStreamTimeout() {
        let repository = MockPersistenceService()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: repository,
                messageStore: repository,
                workspaceStore: repository,
                runtimeRepository: repository,
                toolPersistence: repository
            ),
            workspaceProfile: .hostManaged(root: URL(fileURLWithPath: "/tmp/pk-test")),
            workspaceCreator: MockWorkspaceCreator()
        )
        let dependencies = TurnEngine.Dependencies(
            threadManager: threadManager,
            agentStore: repository,
            requestOriginStore: repository,
            runtimeRepository: repository,
            llmService: MockLLMService(),
            toolRouter: ToolRouter(
                threadManager: threadManager,
                runtimeRepository: repository
            )
        )

        #expect(dependencies.streamTimeout == TurnEngine.Dependencies.defaultStreamTimeout)
        #expect(dependencies.streamTimeout > 0)
    }

    // MARK: - Group 9: Multiple Tool Calls Per Turn

    @Test("Multiple tool calls in one turn are all executed")
    func multipleToolCallsExecuted() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()
            mockLLM.mockClient.nextToolCalls = [[
                MockToolCall(id: "c1", name: "mock_tool"),
                MockToolCall(id: "c2", name: "mock_tool"),
            ]]
            mockLLM.mockClient.nextResponses = ["", "Both done"]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Run two tools",
                    tools: [mockTool.toAnyTool()]
                )
            ))

            let events = try await collect(stream)

            let successIds = events.compactMap { event -> String? in
                if case let .completion(.toolExecution(id, status)) = event,
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
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextResponse = "Done"

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Hi",
                    tools: []
                )
            ))

            let events = try await collect(stream)
            let count = events.filter { if case .completion(.generationCompleted) = $0 { return true }; return false }.count
            #expect(count == 1)
        }
    }

    @Test("Emits generationCompleted event per turn after multi-turn tool execution")
    func generationCompletedPerTurnAfterMultiTurn() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "c1", name: "mock_tool")]]
            mockLLM.mockClient.nextResponses = ["", "Final answer"]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Use tool",
                    tools: [mockTool.toAnyTool()]
                )
            ))

            let events = try await collect(stream)
            // Turn 1 had pending tool calls — no generationCompleted emitted.
            // Turn 2 was a clean text response — exactly one generationCompleted emitted.
            let count = events.filter { if case .completion(.generationCompleted) = $0 { return true }; return false }.count
            #expect(count == 1)
        }
    }

    // MARK: - Group 11: Agent

    @Test("agentId is recorded on the persisted assistant message")
    func agentIdSetOnMessage() async throws {
        let agentId = UUID()
        try await withTurnEngineDependencies(attachedAgentID: agentId) { engine, mockLLM, mockPersistence in
            let agent = Agent(
                id: agentId,
                name: "Test Agent",
                description: "Testing",
                privateThreadID: UUID()
            )
            try await mockPersistence.saveAgent(agent)
            mockLLM.mockClient.nextResponse = "Agent reply"

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    threadID: threadID,
                    message: "Hi agent",
                    tools: []
                ),
                agentID: agentId
            ))

            _ = try await collect(stream)

            let messages = try await mockPersistence.fetchMessages(for: threadID)
            let assistantMsg = messages.first { $0.role == "assistant" }
            #expect(assistantMsg?.agentID == agentId)
        }
    }
}
