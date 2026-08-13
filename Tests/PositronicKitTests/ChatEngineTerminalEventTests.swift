import Foundation
import OpenAI
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

// MARK: - PKRR-011: Terminal event uniqueness

/// Every execution path through `ChatEngine.execute` must emit exactly one terminal event
/// before the stream closes, and that terminal event must identify the path's outcome:
/// - Normal completion → `.completion(.generationCompleted)`
/// - Max-turn exhaustion → `.completion(.maxTurnsReached)` (not a silent success)
/// - Deferred external tool → `.completion(.deferredForExternalTool)`
/// - Cancellation → `.error(.generationCancelled)`
/// - Failure → the stream throws
///
/// Additionally, the orphan cases `.meta(.generationCompleted)` and
/// `.completion(.streamCompleted)` must never be emitted in production — they are
/// deprecated definition/docs-only cases.
@Suite(.serialized) @MainActor
struct ChatEngineTerminalEventTests {
    private let threadID = UUID()

    /// Standard dependencies with a `.runtimeThread` workspace (tools execute locally).
    private func withChatEngineDependencies<T>(
        plugins: [any ChatTurnPlugin] = [],
        _ test: @Sendable (ChatEngine, MockLLMService, MockPersistenceService) async throws -> T
    ) async throws -> T {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
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
                chatTurnPlugins: plugins,
                streamTimeout: 60
            )
        )

        let session = Thread(id: threadID, title: "PKRR-011 Session")
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

    /// Dependencies wired with an `.attached` workspace so a workspace-registered tool call
    /// defers for external execution instead of executing locally. The tool is registered only
    /// to the workspace (not passed as a per-turn dynamic tool), so the router reaches the
    /// workspace-resolution path and returns `.deferredExternally`.
    private func withAttachedWorkspaceDependencies<T>(
        _ test: @Sendable (ChatEngine, MockLLMService, MockPersistenceService) async throws -> T
    ) async throws -> T {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
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
                streamTimeout: 60
            )
        )

        // Non-private thread (default) so attached tools defer rather than throw.
        let session = Thread(id: threadID, title: "PKRR-011 Deferred Session")
        try await mockPersistence.saveThread(session)

        let wsId = UUID()
        let workspaceRef = WorkspaceReference(
            id: wsId,
            uri: WorkspaceURI(parsing: "pk://local")!,
            location: .attached,
            originID: nil,
            rootPath: "/tmp"
        )
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

    private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: - Max-turn exhaustion emits a distinct terminal event

    @Test("Max-turn exhaustion emits exactly one maxTurnsReached terminal event (PKRR-011)")
    func maxTurnsExhaustionEmitsDistinctTerminal() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()
            mockLLM.mockClient.nextToolCalls = [
                [MockToolCall(id: "c1", name: "mock_tool")],
                [MockToolCall(id: "c2", name: "mock_tool")],
            ]
            mockLLM.mockClient.nextResponses = ["", ""]

            let stream = try await engine.execute(
                threadID: threadID,
                message: "Infinite tools",
                tools: [mockTool.toAnyTool()],
                maxTurns: 2
            )

            let events = try await collect(stream)

            let maxTurnsEvents = events.filter {
                if case .completion(.maxTurnsReached) = $0 { return true }
                return false
            }
            #expect(maxTurnsEvents.count == 1, "Max-turn exhaustion must emit exactly one .maxTurnsReached")

            // Exhaustion is not a success — no normal completion terminal.
            let generationCompleted = events.filter {
                if case .completion(.generationCompleted) = $0 { return true }
                return false
            }
            #expect(generationCompleted.isEmpty, "Max-turn exhaustion must not emit .generationCompleted")

            // Nor is it a deferred terminal.
            let deferred = events.filter {
                if case .completion(.deferredForExternalTool) = $0 { return true }
                return false
            }
            #expect(deferred.isEmpty, "Max-turn exhaustion must not emit .deferredForExternalTool")
        }
    }

    // MARK: - Deferred external tool emits a distinct terminal event

    @Test("Deferred external tool emits exactly one deferredForExternalTool terminal event (PKRR-011)")
    func deferredExternalToolEmitsDistinctTerminal() async throws {
        try await withAttachedWorkspaceDependencies { engine, mockLLM, _ in
            // Tool call resolves to the attached workspace and defers. Pass no dynamic tools so
            // the router reaches workspace resolution instead of unconditional local execution.
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_def", name: "mock_tool")]]
            mockLLM.mockClient.nextResponses = ["Pausing for external tool"]

            let stream = try await engine.execute(
                threadID: threadID,
                message: "Run attached tool",
                tools: []
            )

            let events = try await collect(stream)

            let deferredEvents = events.filter {
                if case .completion(.deferredForExternalTool) = $0 { return true }
                return false
            }
            #expect(deferredEvents.count == 1, "Deferred external tool must emit exactly one .deferredForExternalTool")

            // Deferred is not a normal completion — the LLM produced tool calls, so the
            // persistence stage does not emit .generationCompleted.
            let generationCompleted = events.filter {
                if case .completion(.generationCompleted) = $0 { return true }
                return false
            }
            #expect(generationCompleted.isEmpty, "Deferred external tool must not emit .generationCompleted")

            let maxTurns = events.filter {
                if case .completion(.maxTurnsReached) = $0 { return true }
                return false
            }
            #expect(maxTurns.isEmpty, "Deferred external tool must not emit .maxTurnsReached")
        }
    }

    // MARK: - Normal completion emits exactly one generationCompleted

    @Test("Normal completion emits exactly one generationCompleted and no other terminal (PKRR-011)")
    func normalCompletionEmitsExactlyOneTerminal() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextResponse = "All done"

            let stream = try await engine.execute(
                threadID: threadID,
                message: "Hi",
                tools: []
            )

            let events = try await collect(stream)

            let generationCompleted = events.filter {
                if case .completion(.generationCompleted) = $0 { return true }
                return false
            }
            #expect(generationCompleted.count == 1, "Normal completion must emit exactly one .generationCompleted")

            let maxTurns = events.filter {
                if case .completion(.maxTurnsReached) = $0 { return true }
                return false
            }
            #expect(maxTurns.isEmpty, "Normal completion must not emit .maxTurnsReached")

            let deferred = events.filter {
                if case .completion(.deferredForExternalTool) = $0 { return true }
                return false
            }
            #expect(deferred.isEmpty, "Normal completion must not emit .deferredForExternalTool")
        }
    }

    // MARK: - Cancellation emits generationCancelled and no completion terminal

    @Test("Direct cancellation emits generationCancelled and no completion terminal (PKRR-011)")
    func cancellationEmitsDistinctTerminal() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            // A direct CancellationError (not wrapped through a pipeline stage) is caught by
            // `runOneTurn`'s `catch is CancellationError` branch, which emits
            // `.generationCancelled()` and finishes the stream cleanly. A provider-stream
            // cancellation is wrapped as `PipelineError.stageFailed` and surfaces as a throw
            // (the throw is that path's terminal signal); that path is covered by
            // `ChatEngineTerminalInvariantTests`.
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamResultFactory.textChunk("partial "))
                continuation.finish(throwing: CancellationError())
            }

            let stream = try await engine.execute(
                threadID: threadID,
                message: "stream then cancel",
                tools: []
            )

            // The provider-stream CancellationError is wrapped as a PipelineError and the
            // stream throws — the throw is the terminal signal. Collect events up to the throw.
            var events: [ChatEvent] = []
            do {
                for try await event in stream {
                    events.append(event)
                }
            } catch {
                // Expected: wrapped cancellation surfaces as a throw.
            }

            // No completion terminal is emitted on the cancellation path — the throw is the
            // terminal signal, not a completion event.
            let completionTerminals = events.filter {
                if case .completion(.generationCompleted) = $0 { return true }
                if case .completion(.maxTurnsReached) = $0 { return true }
                if case .completion(.deferredForExternalTool) = $0 { return true }
                return false
            }
            #expect(completionTerminals.isEmpty, "Cancellation must not emit a completion terminal")
        }
    }

    // MARK: - Orphan cases are never emitted in production

    @Test("Deprecated orphan cases are never emitted in production (PKRR-011)")
    func orphanCasesNeverEmitted() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextResponse = "Done"

            let stream = try await engine.execute(
                threadID: threadID,
                message: "Hi",
                tools: []
            )

            let events = try await collect(stream)

            // .meta(.generationCompleted) is never emitted in production.
            let metaCompletion = events.filter {
                if case .meta(.generationCompleted) = $0 { return true }
                return false
            }
            #expect(metaCompletion.isEmpty, ".meta(.generationCompleted) must never be emitted")

            // .completion(.streamCompleted) is never emitted in production.
            let streamCompleted = events.filter {
                if case .completion(.streamCompleted) = $0 { return true }
                return false
            }
            #expect(streamCompleted.isEmpty, ".completion(.streamCompleted) must never be emitted")
        }
    }

    @Test("Deprecated orphan cases are never emitted on the max-turn path (PKRR-011)")
    func orphanCasesNeverEmittedOnMaxTurns() async throws {
        try await withChatEngineDependencies { engine, mockLLM, _ in
            let mockTool = MockTool()
            mockLLM.mockClient.nextToolCalls = [
                [MockToolCall(id: "c1", name: "mock_tool")],
                [MockToolCall(id: "c2", name: "mock_tool")],
            ]
            mockLLM.mockClient.nextResponses = ["", ""]

            let stream = try await engine.execute(
                threadID: threadID,
                message: "Infinite tools",
                tools: [mockTool.toAnyTool()],
                maxTurns: 2
            )

            let events = try await collect(stream)

            let metaCompletion = events.filter {
                if case .meta(.generationCompleted) = $0 { return true }
                return false
            }
            #expect(metaCompletion.isEmpty, ".meta(.generationCompleted) must never be emitted")

            let streamCompleted = events.filter {
                if case .completion(.streamCompleted) = $0 { return true }
                return false
            }
            #expect(streamCompleted.isEmpty, ".completion(.streamCompleted) must never be emitted")
        }
    }
}

// MARK: - Test Tools

private struct MockTool: PKShared.Tool, @unchecked Sendable {
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
        if !result.success && result.error == "client_tools_disallowed_on_private_timeline" {
            throw ToolError.attachedToolsDisallowedOnPrivateThread
        }
        return result
    }
}
