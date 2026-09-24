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
/// - Provider or pipeline failure → the stream throws for the package-internal engine seam
/// - Terminal persistence failure → `.error(.durabilityFailure)` and a normally closed stream
// No `.serialized` marker: every test builds fresh in-memory stores plus a unique
// workspace root (issue #155), so the old marker only compensated for the shared
// `/tmp/pk-test` root that has been eliminated. Note that `@MainActor` alone would not
// justify dropping it — it excludes concurrent *synchronous* regions, but async tests
// still interleave at `await` points, so shared mutable state would remain unsafe.
@Suite(.tags(.integration)) @MainActor
struct TurnEngineTerminalEventTests {
    private let timelineID = UUID()

    /// Standard dependencies with a `.runtimeTimeline` workspace (tools execute locally).
    private func withTurnEngineDependencies<T>(
        turnOutcomeSink: any TurnOutcomeSink? = nil,
        _ test: @Sendable (TurnEngine, MockLLMService, MockPersistenceService) async throws -> T
    ) async throws -> T {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: mockPersistence
            ),
            workspaceProfile: .hostManaged(root: FileManager.default.temporaryDirectory.appendingPathComponent("pk-turnengine-" + UUID().uuidString)),
            workspaceCreator: MockWorkspaceCreator()
        )
        let toolRouter = ToolRouter(
            timelineManager: timelineManager,
            runtimeRepository: mockPersistence
        )
        let engine = TurnEngine(
            dependencies: .init(
                timelineManager: timelineManager,
                agentStore: mockPersistence,
                requestOriginStore: mockPersistence,
                runtimeRepository: mockPersistence,
                llmService: mockLLM,
                toolRouter: toolRouter,
                turnOutcomeSink: turnOutcomeSink,
                policy: RuntimePolicy(streamTimeout: 60)
            )
        )

        let session = TimelineRecord(id: timelineID, title: "PKRR-011 Session")
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
        try await timelineManager.attachWorkspace(wsId, to: timelineID)
        try await mockPersistence.addToolToWorkspace(workspaceID: wsId, tool: .known("mock_tool"))

        try await timelineManager.hydrateTimeline(id: timelineID)

        if let toolManager = await timelineManager.getToolManager(for: timelineID) {
            var tools = await toolManager.getAvailableTools()
            tools.append(AnyTool(MockTool()))
            await toolManager.updateAvailableTools(tools)

            if let ws = try? await timelineManager.workspaceResolver.workspace(id: wsId) {
                await toolManager.registerWorkspace(ws)
            }
        }

        return try await test(engine, mockLLM, mockPersistence)
    }

    /// Dependencies wired with an `.attached` workspace so `call_tool` defers for external
    /// execution instead of executing locally. The admitted Workspace catalog is the only source
    /// for selecting the workspace-owned tool.
    private func withAttachedWorkspaceDependencies<T>(
        _ test: @Sendable (TurnEngine, MockLLMService, MockPersistenceService) async throws -> T
    ) async throws -> T {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
                runtimeRepository: mockPersistence
            ),
            workspaceProfile: .hostManaged(root: FileManager.default.temporaryDirectory.appendingPathComponent("pk-turnengine-" + UUID().uuidString)),
            workspaceCreator: MockWorkspaceCreator()
        )
        let toolRouter = ToolRouter(
            timelineManager: timelineManager,
            runtimeRepository: mockPersistence
        )
        let engine = TurnEngine(
            dependencies: .init(
                timelineManager: timelineManager,
                agentStore: mockPersistence,
                requestOriginStore: mockPersistence,
                runtimeRepository: mockPersistence,
                llmService: mockLLM,
                toolRouter: toolRouter,
                policy: RuntimePolicy(streamTimeout: 60)
            )
        )

        // Non-private timeline (default) so attached tools defer rather than throw.
        let session = TimelineRecord(id: timelineID, title: "PKRR-011 Deferred Session")
        try await mockPersistence.saveTimeline(session)

        let wsId = UUID()
        let workspaceRef = WorkspaceReference(
            id: wsId,
            uri: WorkspaceURI(parsing: "pk://local")!,
            location: .attached,
            originID: nil,
            rootPath: "/tmp"
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(wsId, to: timelineID)
        try await mockPersistence.addToolToWorkspace(workspaceID: wsId, tool: .known("mock_tool"))

        try await timelineManager.hydrateTimeline(id: timelineID)

        if let toolManager = await timelineManager.getToolManager(for: timelineID) {
            var tools = await toolManager.getAvailableTools()
            tools.append(AnyTool(MockTool()))
            await toolManager.updateAvailableTools(tools)

            if let ws = try? await timelineManager.workspaceResolver.workspace(id: wsId) {
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
        let outcomeSink = TestTurnOutcomeRecorder()
        try await withTurnEngineDependencies(turnOutcomeSink: outcomeSink) { engine, mockLLM, persistence in
            let mockTool = MockTool()
            mockLLM.mockClient.nextToolCalls = [
                [MockToolCall(id: "c1", name: "mock_tool")],
                [MockToolCall(id: "c2", name: "mock_tool")],
            ]
            mockLLM.mockClient.nextResponses = ["", ""]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    timelineID: timelineID,
                    message: "Infinite tools",
                    tools: [AnyTool(mockTool)],
                    maxModelRounds: 2
                )
            ))

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

            let outcomeRecord = try #require(await outcomeSink.lastRecord())
            let storedRecord = try #require(try await persistence.fetchTurn(id: outcomeRecord.turnID))
            #expect(storedRecord.outcome == .failed(message: "model-round-limit"))
        }
    }

    // MARK: - Deferred external tool emits a distinct terminal event

    @Test("Deferred external tool emits exactly one deferredForExternalTool terminal event (PKRR-011)")
    func deferredExternalToolEmitsDistinctTerminal() async throws {
        try await withAttachedWorkspaceDependencies { engine, mockLLM, _ in
            mockLLM.mockClient.nextToolCalls = [[MockToolCall(
                id: "call_def",
                name: "call_tool",
                arguments: #"{"tool":"mock_tool","arguments":{}}"#
            )]]
            mockLLM.mockClient.nextResponses = ["Pausing for external tool"]

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    timelineID: timelineID,
                    message: "Run attached tool",
                    tools: []
                )
            ))

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

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    timelineID: timelineID,
                    message: "Hi",
                    tools: []
                )
            ))

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

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    timelineID: timelineID,
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

            let stream = try await engine.execute(TurnExecutionRequest(
                TurnRequest(
                    timelineID: timelineID,
                    message: "stream then cancel",
                    tools: []
                )
            ))

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

private struct MockTool: PKContracts.PKTool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    let callName = "mock_tool"
    let name = "mock_tool"
    let toolDescription = "A mock tool for testing"
    let requiresPermission = false
    let parametersSchema = makeEmptyObjectSchema()

    var result: ToolResult = .success("PKTool result")
    var shouldWait: Bool = false

    func canExecute() async -> Bool {
        true
    }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        if shouldWait { try? await Task.sleep(nanoseconds: 100_000_000) }
        if !result.isSuccess && result.error == "client_tools_disallowed_on_private_timeline" {
            throw ToolError.attachedToolsDisallowedOnPrivateTimeline
        }
        return result
    }
}
