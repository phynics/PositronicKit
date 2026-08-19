import Foundation
import Logging
import OpenAI
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

// MARK: - STAB-1: Partial assistant turn persistence on stream failure/cancellation

/// When the LLM stream fails mid-flight (network drop, provider 4xx/5xx, idle timeout, or
/// cancellation), the partial assistant text/thinking the user already watched stream in must
/// still be persisted — tagged so it's distinguishable from a complete turn. These tests drive
/// the full `ChatEngine` turn loop (not a bare stage) so the error-path persistence in
/// `runOneTurn` is exercised end to end.
@Suite(.serialized) @MainActor
struct ChatEngineFailurePersistenceTests {
    private let threadID = UUID()

    /// Mirrors `ChatEngineTests.withChatEngineDependencies` but is kept local so this suite is
    /// self-contained. Seeds a hydrated thread the engine can run a turn against.
    private func withChatEngineDependencies<T>(
        streamTimeout: TimeInterval = 60,
        promptHistoryRegistry: ThreadPromptJournals? = nil,
        _ test: @Sendable (ChatEngine, MockLLMService, MockPersistenceService) async throws -> T
    ) async throws -> T {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let registry = promptHistoryRegistry ?? ThreadPromptJournals()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspaceCreator: MockWorkspaceCreator()
        )
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            messageStore: mockPersistence
        )
        let engine = ChatEngine(
            dependencies: .init(
                threadManager: threadManager,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence,
                messageStore: mockPersistence,
                llmService: mockLLM,
                toolRouter: toolRouter,
                chatTurnPlugins: [],
                promptHistoryRegistry: registry,
                streamTimeout: streamTimeout
            )
        )

        let session = Thread(id: threadID, title: "STAB-1 Session")
        try await mockPersistence.saveThread(session)

        let wsId = UUID()
        let workspaceRef = WorkspaceReference(
            id: wsId,
            uri: WorkspaceURI(parsing: "pk://local")!,
            location: .runtimeThread,
            originID: nil,
            rootPath: "/tmp"
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(wsId, to: threadID)
        try await mockPersistence.addToolToWorkspace(workspaceId: wsId, tool: .known("mock_tool"))

        try await threadManager.hydrateThread(id: threadID)

        return try await test(engine, mockLLM, mockPersistence)
    }

    /// Uses a message store that admits the user and assistant rows, then fails the first tool
    /// result save. The same store can be reopened for the retry assertion below.
    private func withToolResultPersistenceFailureDependencies<T>(
        _ test: @Sendable (ChatEngine, MockLLMService, BatchFailingMessageStore) async throws -> T
    ) async throws -> T {
        let mockLLM = MockLLMService()
        let backing = MockPersistenceService()
        let messageStore = BatchFailingMessageStore()
        messageStore.failAfterSaveCount = 2
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: backing,
                messageStore: messageStore,
                workspaceStore: backing,
                toolPersistence: backing
            ),
            workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
            workspaceCreator: MockWorkspaceCreator()
        )
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            messageStore: messageStore
        )
        let engine = ChatEngine(
            dependencies: .init(
                threadManager: threadManager,
                agentInstanceStore: backing,
                requestOriginStore: backing,
                messageStore: messageStore,
                llmService: mockLLM,
                toolRouter: toolRouter,
                chatTurnPlugins: [],
                streamTimeout: 60
            )
        )

        let session = Thread(id: threadID, title: "Tool persistence failure")
        try await backing.saveThread(session)
        let wsId = UUID()
        let workspaceRef = WorkspaceReference(
            id: wsId,
            uri: WorkspaceURI(parsing: "pk://local")!,
            location: .runtimeThread,
            originID: nil,
            rootPath: "/tmp"
        )
        try await backing.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(wsId, to: threadID)
        try await backing.addToolToWorkspace(workspaceId: wsId, tool: .known(PersistenceTestTool.toolID))
        try await threadManager.hydrateThread(id: threadID)
        if let toolManager = await threadManager.getToolManager(for: threadID) {
            await toolManager.updateAvailableTools([PersistenceTestTool().toAnyTool()])
        }

        return try await test(engine, mockLLM, messageStore)
    }

    private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: - Failure path → `.partial`

    @Test("A stream that fails after emitting text persists a .partial assistant message (STAB-1)")
    func streamFailureAfterTextPersistsPartialAssistant() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            // Simulate a provider stream that emits two content chunks then drops (e.g. network
            // error / provider 5xx). The mock stream throws a non-cancellation error.
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamResultFactory.textChunk("Hello partial "))
                continuation.yield(ChatStreamResultFactory.textChunk("world"))
                continuation.finish(throwing: NSError(
                    domain: "STAB1ProviderDrop", code: 503,
                    userInfo: [NSLocalizedDescriptionKey: "simulated provider 5xx"]
                ))
            }

            let stream = try await engine.execute(
                threadID: threadID,
                message: "stream then fail",
                tools: []
            )

            // The turn is recorded as failed: the stream surfaces the error (re-thrown), it is
            // NOT swallowed.
            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            let messages = try await mockPersistence.fetchMessages(for: threadID)

            // The user message (persisted during prepareSession) must remain.
            let userMessages = messages.filter { $0.role == "user" }
            #expect(userMessages.count == 1)
            #expect(userMessages[0].content == "stream then fail")

            // Exactly one assistant row, tagged `.partial`, carrying the streamed text.
            let assistantMessages = messages.filter { $0.role == "assistant" }
            #expect(assistantMessages.count == 1)
            let assistant = try #require(assistantMessages.first)
            #expect(assistant.content == "Hello partial world")
            #expect(assistant.status == .partial)
        }
    }

    @Test("A tool-result persistence failure stops the loop and leaves the call retryable")
    func toolResultPersistenceFailureStopsLoopAndLeavesPendingCall() async throws {
        try await withToolResultPersistenceFailureDependencies { engine, mockLLM, messageStore in
            let sendID = UUID()
            let tool = PersistenceTestTool()
            mockLLM.mockClient.nextResponses = [""]
            mockLLM.mockClient.nextToolCalls = [[
                MockToolCall(id: "persist_retry_call", name: tool.callName)
            ]]

            let failedStream = try await engine.execute(
                threadID: threadID,
                sendId: sendID,
                message: "run the retryable tool",
                tools: [tool.toAnyTool()]
            )
            let failedEvents = try await collect(failedStream)

            #expect(failedEvents.contains(where: {
                if case let .completion(.toolExecution(toolCallId, status)) = $0,
                   case .persistenceFailed = status
                {
                    return toolCallId == "persist_retry_call"
                }
                return false
            }))
            #expect(!failedEvents.contains(where: {
                if case .completion(.generationCompleted) = $0 { return true }
                return false
            }))
            #expect(mockLLM.chatCaptureHistory.count == 1)

            let pendingMessages = try await messageStore.fetchMessages(for: threadID)
            #expect(pendingMessages.filter { $0.role == "assistant" }.count == 1)
            #expect(pendingMessages.filter { $0.role == "tool" }.isEmpty)
            let pendingAssistant = try #require(pendingMessages.first { $0.role == "assistant" })
            #expect(pendingAssistant.toolCalls != "[]")

            // The failed send released its reservation. Persist the same output through the
            // existing pending-call submission path and verify the loop can recover.
            messageStore.failAfterSaveCount = nil
            mockLLM.mockClient.nextToolCalls = []
            mockLLM.mockClient.nextResponse = "Recovered after retry"
            let retryStream = try await engine.execute(
                threadID: threadID,
                sendId: sendID,
                message: "",
                tools: [tool.toAnyTool()],
                toolOutputs: [ToolOutputSubmission(
                    toolCallID: "persist_retry_call",
                    output: "durable retry result"
                )]
            )
            let retryEvents = try await collect(retryStream)

            #expect(retryEvents.contains(where: {
                if case .completion(.generationCompleted) = $0 { return true }
                return false
            }))
            #expect(mockLLM.chatCaptureHistory.count == 2)
            let recoveredMessages = try await messageStore.fetchMessages(for: threadID)
            #expect(recoveredMessages.filter { $0.role == "tool" && $0.toolCallID == "persist_retry_call" }.count == 1)
            #expect(recoveredMessages.filter { $0.role == "assistant" }.count == 2)
        }
    }

    @Test("A post-yield failure releases its send ID for a retry without duplicating user input")
    func postYieldFailureReleasesSendIDForRetry() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            let sendID = UUID()
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamResultFactory.toolCallChunk(
                    calls: [MockToolCall(id: "retry_call", name: "external_tool")],
                    content: "partial "
                ))
                continuation.finish(throwing: NSError(
                    domain: "PK46ProviderDrop",
                    code: 503,
                    userInfo: [NSLocalizedDescriptionKey: "simulated provider 5xx"]
                ))
            }

            let failedStream = try await engine.execute(
                threadID: threadID,
                sendId: sendID,
                message: "start external work",
                tools: []
            )
            await #expect(throws: Error.self) {
                _ = try await collect(failedStream)
            }

            // Retry the same logical send with the durable external-tool result. The original
            // user input must remain a singleton while the retry reaches the provider.
            mockLLM.stubbedStream = nil
            mockLLM.mockClient.nextResponse = "retry succeeded"
            let retryStream = try await engine.execute(
                threadID: threadID,
                sendId: sendID,
                message: "",
                tools: [],
                toolOutputs: [ToolOutputSubmission(toolCallID: "retry_call", output: "done")]
            )
            let retryEvents = try await collect(retryStream)

            #expect(retryEvents.contains(where: {
                if case .completion(.generationCompleted) = $0 { return true }
                return false
            }))
            #expect(mockLLM.chatCaptureHistory.count == 2, "Retry must reach the provider")

            let messages = try await mockPersistence.fetchMessages(for: threadID)
            #expect(messages.filter { $0.role == "user" }.count == 1)
            #expect(messages.filter { $0.role == "tool" && $0.toolCallID == "retry_call" }.count == 1)
        }
    }

    @Test("A fail-once prompt-history update retries inputs idempotently")
    func promptHistoryFailureRetryIsInputIdempotent() async throws {
        let registry = ThreadPromptJournals()
        try await withChatEngineDependencies(promptHistoryRegistry: registry) { engine, mockLLM, mockPersistence in
            let sendID = UUID()
            let toolCallID = "history_retry_call"
            let toolCalls = [ToolCall(id: toolCallID, name: "external_tool", arguments: [:])]
            let toolCallsData = try SerializationUtils.jsonEncoder.encode(toolCalls)
            try await mockPersistence.saveMessage(ConversationMessage(
                threadID: threadID,
                role: .assistant,
                content: "",
                toolCalls: String(decoding: toolCallsData, as: UTF8.self)
            ))

            let history = await registry.history(for: threadID)
            await history.failNextUpdate(with: .duplicateSectionIDs(["fail-once"]))

            do {
                _ = try await engine.execute(
                    threadID: threadID,
                    sendId: sendID,
                    message: "retry after history failure",
                    tools: [],
                    toolOutputs: [ToolOutputSubmission(toolCallID: toolCallID, output: "tool result")]
                )
                Issue.record("Expected the fail-once prompt-history update to throw")
            } catch let error as ChatEngineError {
                guard case let .promptHistoryInconsistent(detail) = error else {
                    Issue.record("Expected promptHistoryInconsistent, got \(error)")
                    return
                }
                #expect(detail.contains("fail-once"), "The original prompt-history error must remain diagnosable")
            } catch {
                Issue.record("Expected ChatEngineError.promptHistoryInconsistent, got \(error)")
            }

            let messagesAfterFailure = try await mockPersistence.fetchMessages(for: threadID)
            #expect(messagesAfterFailure.filter { $0.role == "user" }.isEmpty)
            #expect(messagesAfterFailure.filter { $0.role == "tool" }.isEmpty)

            mockLLM.mockClient.nextResponse = "Recovered reply"
            let retryStream = try await engine.execute(
                threadID: threadID,
                sendId: sendID,
                message: "retry after history failure",
                tools: [],
                toolOutputs: [ToolOutputSubmission(toolCallID: toolCallID, output: "tool result")]
            )
            _ = try await collect(retryStream)

            let messagesAfterRetry = try await mockPersistence.fetchMessages(for: threadID)
            let userMessages = messagesAfterRetry.filter { $0.role == "user" }
            #expect(userMessages.count == 1)
            #expect(userMessages.first?.id == sendID)
            #expect(messagesAfterRetry.filter { $0.role == "tool" && $0.toolCallID == toolCallID }.count == 1)
        }
    }

    // MARK: - Cancellation path → `.cancelled`

    @Test("A stream cancelled after emitting text persists a .cancelled assistant message (STAB-1)")
    func streamCancellationAfterTextPersistsCancelledAssistant() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            // Simulate a provider stream that emits content then is cancelled mid-flight. A
            // stage-thrown `CancellationError` is wrapped by `Pipeline` as
            // `PipelineError.stageFailed` before reaching `runOneTurn`; `ChatEngine` unwraps it
            // so the partial turn is tagged `.cancelled` rather than `.partial`.
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamResultFactory.textChunk("Cancelled "))
                continuation.yield(ChatStreamResultFactory.textChunk("mid-stream"))
                continuation.finish(throwing: CancellationError())
            }

            let stream = try await engine.execute(
                threadID: threadID,
                message: "stream then cancel",
                tools: []
            )

            // The error event is still surfaced (do NOT swallow) — the stream re-throws.
            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            let messages = try await mockPersistence.fetchMessages(for: threadID)

            let userMessages = messages.filter { $0.role == "user" }
            #expect(userMessages.count == 1)
            #expect(userMessages[0].content == "stream then cancel")

            let assistantMessages = messages.filter { $0.role == "assistant" }
            #expect(assistantMessages.count == 1)
            let assistant = try #require(assistantMessages.first)
            #expect(assistant.content == "Cancelled mid-stream")
            #expect(assistant.status == .cancelled)
        }
    }

    @Test("A cancelled stream releases its send ID for a retry")
    func cancelledStreamReleasesSendIDForRetry() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            let sendID = UUID()
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamResultFactory.toolCallChunk(
                    calls: [MockToolCall(id: "cancel_retry_call", name: "external_tool")],
                    content: "partial "
                ))
                continuation.finish(throwing: CancellationError())
            }

            let cancelledStream = try await engine.execute(
                threadID: threadID,
                sendId: sendID,
                message: "start cancellable work",
                tools: []
            )
            await #expect(throws: Error.self) {
                _ = try await collect(cancelledStream)
            }

            mockLLM.stubbedStream = nil
            mockLLM.mockClient.nextResponse = "retry after cancellation"
            let retryStream = try await engine.execute(
                threadID: threadID,
                sendId: sendID,
                message: "",
                tools: [],
                toolOutputs: [ToolOutputSubmission(toolCallID: "cancel_retry_call", output: "done")]
            )
            _ = try await collect(retryStream)

            #expect(mockLLM.chatCaptureHistory.count == 2, "Cancellation retry must reach the provider")
            let messages = try await mockPersistence.fetchMessages(for: threadID)
            #expect(messages.filter { $0.role == "user" }.count == 1)
            #expect(messages.filter { $0.role == "tool" && $0.toolCallID == "cancel_retry_call" }.count == 1)
        }
    }

    // MARK: - Success regression guard → untagged (`.complete`/nil)

    @Test("A clean successful turn persists an assistant message with no partial tag (STAB-1 regression)")
    func successfulTurnPersistsUntaggedAssistant() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            mockLLM.mockClient.nextResponse = "Clean complete reply"

            let stream = try await engine.execute(
                threadID: threadID,
                message: "succeed cleanly",
                tools: []
            )

            let events = try await collect(stream)

            // Happy path still emits the completion event (success flow unchanged).
            #expect(events.contains(where: {
                if case .completion(.generationCompleted) = $0 { return true }
                return false
            }))

            let messages = try await mockPersistence.fetchMessages(for: threadID)

            let userMessages = messages.filter { $0.role == "user" }
            #expect(userMessages.count == 1)

            let assistantMessages = messages.filter { $0.role == "assistant" }
            #expect(assistantMessages.count == 1)
            let assistant = try #require(assistantMessages.first)
            #expect(assistant.content == "Clean complete reply")
            // Success path is byte-identical: status is `nil` (semantically `.complete`).
            #expect(assistant.status == nil)
        }
    }

    @Test("An extension-stage failure does not duplicate a persisted assistant message")
    func extensionStageFailureDoesNotDuplicateAssistant() async throws {
        try await withChatEngineDependencies { baseEngine, mockLLM, mockPersistence in
            var engine = baseEngine
            engine.additionalStages = [ThrowingExtensionStage()]
            mockLLM.mockClient.nextResponse = "Complete before extension failure"

            let stream = try await engine.execute(
                threadID: threadID,
                message: "extension stage fails",
                tools: []
            )

            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            let assistantMessages = try await mockPersistence.fetchMessages(for: threadID)
                .filter { $0.role == "assistant" }
            #expect(assistantMessages.count == 1)
            #expect(assistantMessages[0].content == "Complete before extension failure")
            #expect(assistantMessages[0].status == nil)
        }
    }

    // MARK: - Empty-outputs threshold

    @Test("A stream that fails before emitting any content does not persist an empty assistant row (STAB-1)")
    func streamFailureWithNoContentSkipsPersistence() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            // Fails immediately, before any text/thinking/tool calls — threshold says skip to
            // avoid a spurious empty assistant row. The user message remains the turn's record.
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(
                    domain: "STAB1ProviderDrop", code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "simulated provider 5xx"]
                ))
            }

            let stream = try await engine.execute(
                threadID: threadID,
                message: "fail immediately",
                tools: []
            )

            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            let messages = try await mockPersistence.fetchMessages(for: threadID)
            // Only the user message; no empty assistant row.
            #expect(messages.count == 1)
            #expect(messages[0].role == "user")
        }
    }

    // MARK: - PKLOG-004: Foreign provider errors carry a PKError domain/code

    @Test("A foreign provider stream error is wrapped as an LLMStreamError under PipelineError (PKLOG-004)")
    func foreignProviderErrorWrappedWithDomainAndCode() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            // A fully foreign error (NSError) with no PKError domain/code — the kind a provider
            // transport layer throws before the runtime wraps it.
            let foreignError = NSError(
                domain: "PKLOG004Foreign", code: 42,
                userInfo: [NSLocalizedDescriptionKey: "simulated provider transport failure"]
            )
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamResultFactory.textChunk("partial "))
                continuation.finish(throwing: foreignError)
            }

            let stream = try await engine.execute(
                threadID: threadID,
                message: "foreign drop",
                tools: []
            )

            do {
                _ = try await collect(stream)
                Issue.record("Expected the stream to throw the wrapped provider error")
            } catch let PipelineError.stageFailed(_, underlying) {
                // The foreign error is wrapped as LLMStreamError (PKError) at the stage leak
                // point, before the pipeline re-wraps it — so the underlying carries a stable
                // domain/code rather than a bare NSError.
                let streamError = try #require(underlying as? LLMStreamError)
                #expect(streamError.errorDomain == PKErrorDomain.llm)
                #expect(streamError.errorCode == 1005)
                // The original foreign error is preserved as the underlying cause.
                let ns = streamError.underlyingError as NSError
                #expect(ns.domain == "PKLOG004Foreign")
                #expect(ns.code == 42)
            } catch {
                Issue.record("Expected PipelineError.stageFailed wrapping LLMStreamError, got \(error)")
            }
        }
    }

    @Test("A cancellation error reaches callers unwrapped (PKLOG-004)")
    func cancellationErrorPassesThroughUnwrapped() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamResultFactory.textChunk("cancel me "))
                continuation.finish(throwing: CancellationError())
            }

            let stream = try await engine.execute(
                threadID: threadID,
                message: "cancel stream",
                tools: []
            )

            do {
                _ = try await collect(stream)
                Issue.record("Expected the stream to throw on cancellation")
            } catch let PipelineError.stageFailed(_, underlying) {
                // CancellationError passes through wrapForeignError unchanged — it is NOT
                // wrapped as LLMStreamError, so the loop's cancellation detection still works.
                #expect(underlying is CancellationError)
                #expect(underlying is LLMStreamError == false)
            } catch {
                Issue.record("Expected PipelineError.stageFailed wrapping CancellationError, got \(error)")
            }
        }
    }

    @Test("WorkspaceError.accessDenied is classified as blocked (PKAPI-004)")
    func workspaceErrorAccessDeniedIsBlocked() {
        // WorkspaceError lives in PositronicKit, so its blocked classification is
        // tested here rather than in PKSharedTests/ChatEventTests.
        let identity = ChatEvent.ErrorIdentity.extracting(from: WorkspaceError.accessDenied)
        #expect(identity?.domain == PKErrorDomain.workspace)
        #expect(identity?.code == 3002)
        #expect(identity?.isBlocked == true, "Expected WorkspaceError.accessDenied to be blocked")
    }
}

private struct ThrowingExtensionStage: PipelineStage {
    func process(_: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        throw NSError(
            domain: "STAB48ExtensionStage",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "simulated extension failure"]
        )
    }
}

private struct PersistenceTestTool: PKShared.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    static let toolID = "retryable_tool"

    let callName = Self.toolID
    let name = Self.toolID
    let description = "A tool for persistence retry tests"
    let requiresPermission = false
    let parametersSchema = makeEmptyObjectSchema()

    func canExecute() async -> Bool { true }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        .success("tool output")
    }
}
