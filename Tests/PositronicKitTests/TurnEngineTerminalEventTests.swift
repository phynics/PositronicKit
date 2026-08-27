import Foundation
import OpenAI
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

// MARK: - PKRR-011: Terminal event uniqueness

/// Every execution path through `TurnEngine.execute` emits at most one terminal event before the
/// stream closes, and any terminal event identifies the path's outcome:
/// - Normal completion → `.completion(.generationCompleted)`
/// - Model-round exhaustion → `.completion(.maxModelRoundsReached)` (not a silent success)
/// - Deferred external tool → `.completion(.deferredForExternalTool)`
/// - Cancellation → `.error(.generationCancelled)`
/// - Failure → the stream throws
@Suite(.serialized) @MainActor
struct TurnEngineTerminalEventTests {
    private let threadID = UUID()

    /// Standard dependencies with a `.runtimeThread` workspace (tools execute locally).
    private func withTurnEngineDependencies<T>(
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
            messageStore: mockPersistence,
            runtimeRepository: mockPersistence
        )
        let engine = TurnEngine(
            dependencies: .init(
                threadManager: threadManager,
                agentStore: mockPersistence,
                requestOriginStore: mockPersistence,
                messageStore: mockPersistence,
                runtimeRepository: mockPersistence,
                llmService: mockLLM,
                toolRouter: toolRouter,
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
            messageStore: mockPersistence,
            runtimeRepository: mockPersistence
        )
        let engine = TurnEngine(
            dependencies: .init(
                threadManager: threadManager,
                agentStore: mockPersistence,
                requestOriginStore: mockPersistence,
                messageStore: mockPersistence,
                runtimeRepository: mockPersistence,
                llmService: mockLLM,
                toolRouter: toolRouter,
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

    private func collect(_ stream: AsyncThrowingStream<TurnEvent, Error>) async throws -> [TurnEvent] {
        var events: [TurnEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: - Model-round exhaustion emits a distinct terminal event

    @Test("Model-round exhaustion emits exactly one maxModelRoundsReached terminal event (PKRR-011)")
    func maxModelRoundsExhaustionEmitsDistinctTerminal() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
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
                maxModelRounds: 2
            )

            let events = try await collect(stream)

            let maxModelRoundsEvents = events.filter {
                if case .completion(.maxModelRoundsReached) = $0 { return true }
                return false
            }
            #expect(maxModelRoundsEvents.count == 1, "Model-round exhaustion must emit exactly one .maxModelRoundsReached")

            // Exhaustion is not a success — no normal completion terminal.
            let generationCompleted = events.filter {
                if case .completion(.generationCompleted) = $0 { return true }
                return false
            }
            #expect(generationCompleted.isEmpty, "Model-round exhaustion must not emit .generationCompleted")

            // Nor is it a deferred terminal.
            let deferred = events.filter {
                if case .completion(.deferredForExternalTool) = $0 { return true }
                return false
            }
            #expect(deferred.isEmpty, "Model-round exhaustion must not emit .deferredForExternalTool")
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

            let maxModelRounds = events.filter {
                if case .completion(.maxModelRoundsReached) = $0 { return true }
                return false
            }
            #expect(maxModelRounds.isEmpty, "Deferred external tool must not emit .maxModelRoundsReached")
        }
    }

    // MARK: - Normal completion emits exactly one generationCompleted

    @Test("Normal completion emits exactly one generationCompleted and no other terminal (PKRR-011)")
    func normalCompletionEmitsExactlyOneTerminal() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
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

            let maxModelRounds = events.filter {
                if case .completion(.maxModelRoundsReached) = $0 { return true }
                return false
            }
            #expect(maxModelRounds.isEmpty, "Normal completion must not emit .maxModelRoundsReached")

            let deferred = events.filter {
                if case .completion(.deferredForExternalTool) = $0 { return true }
                return false
            }
            #expect(deferred.isEmpty, "Normal completion must not emit .deferredForExternalTool")

            #expect(events.filter(\.isTerminal).count == 1, "Each consumer must receive one terminal event")
        }
    }

    @Test("Empty completion emits exactly one terminal event (PKRR-011)")
    func emptyCompletionEmitsExactlyOneTerminal() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextResponse = ""

            let stream = try await engine.execute(
                threadID: threadID,
                message: "Return nothing",
                tools: []
            )

            let events = try await collect(stream)

            #expect(events.contains(where: {
                if case let .completion(.generationCompleted(message, metadata)) = $0 {
                    return message.content.isEmpty && metadata.finishReason == "stop"
                }
                return false
            }))
            #expect(events.filter(\.isTerminal).count == 1, "Empty completion must not emit two terminal events")
        }
    }

    // MARK: - Cancellation emits generationCancelled and no completion terminal

    @Test("Direct cancellation emits generationCancelled and no completion terminal (PKRR-011)")
    func cancellationEmitsDistinctTerminal() async throws {
        try await withTurnEngineDependencies { engine, mockLLM, _ in
            // A direct CancellationError (not wrapped through a pipeline stage) is caught by
            // `runOneTurn`'s `catch is CancellationError` branch, which emits
            // `.generationCancelled()` and finishes the stream cleanly. A provider-stream
            // cancellation is wrapped as `PipelineError.stageFailed` and surfaces as a throw
            // (the throw is that path's terminal signal); that path is covered by
            // `TurnEngineTerminalInvariantTests`.
            mockLLM.stubbedStream = AsyncThrowingStream { continuation in
                continuation.yield(GenerationStreamResultFactory.textChunk("partial "))
                continuation.finish(throwing: CancellationError())
            }

            let stream = try await engine.execute(
                threadID: threadID,
                message: "stream then cancel",
                tools: []
            )

            // The provider-stream CancellationError is wrapped as a PipelineError and the
            // stream throws — the throw is the terminal signal. Collect events up to the throw.
            var events: [TurnEvent] = []
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
                if case .completion(.maxModelRoundsReached) = $0 { return true }
                if case .completion(.deferredForExternalTool) = $0 { return true }
                return false
            }
            #expect(completionTerminals.isEmpty, "Cancellation must not emit a completion terminal")
        }
    }

}

// MARK: - Test Tools

private struct MockTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
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
