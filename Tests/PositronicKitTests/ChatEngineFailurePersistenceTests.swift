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
    private let timelineId = UUID()

    /// Mirrors `ChatEngineTests.withChatEngineDependencies` but is kept local so this suite is
    /// self-contained. Seeds a hydrated timeline the engine can run a turn against.
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

        let session = Timeline(id: timelineId, title: "STAB-1 Session")
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
                timelineId: timelineId,
                message: "stream then fail",
                tools: []
            )

            // The turn is recorded as failed: the stream surfaces the error (re-thrown), it is
            // NOT swallowed.
            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            let messages = try await mockPersistence.fetchMessages(for: timelineId)

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
                timelineId: timelineId,
                message: "stream then cancel",
                tools: []
            )

            // The error event is still surfaced (do NOT swallow) — the stream re-throws.
            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            let messages = try await mockPersistence.fetchMessages(for: timelineId)

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

    // MARK: - Success regression guard → untagged (`.complete`/nil)

    @Test("A clean successful turn persists an assistant message with no partial tag (STAB-1 regression)")
    func successfulTurnPersistsUntaggedAssistant() async throws {
        try await withChatEngineDependencies { engine, mockLLM, mockPersistence in
            mockLLM.mockClient.nextResponse = "Clean complete reply"

            let stream = try await engine.execute(
                timelineId: timelineId,
                message: "succeed cleanly",
                tools: []
            )

            let events = try await collect(stream)

            // Happy path still emits the completion event (success flow unchanged).
            #expect(events.contains(where: {
                if case .completion(.generationCompleted) = $0 { return true }
                return false
            }))

            let messages = try await mockPersistence.fetchMessages(for: timelineId)

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
                timelineId: timelineId,
                message: "fail immediately",
                tools: []
            )

            await #expect(throws: Error.self) {
                _ = try await collect(stream)
            }

            let messages = try await mockPersistence.fetchMessages(for: timelineId)
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
                timelineId: timelineId,
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
                timelineId: timelineId,
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
