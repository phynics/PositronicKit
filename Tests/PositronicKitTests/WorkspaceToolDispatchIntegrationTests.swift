import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

@Suite("Workspace tool dispatch integration", .serialized)
struct WorkspaceToolDispatchIntegrationTests {
    private actor ExecutionProbe {
        private(set) var executionCount = 0

        func recordExecution() {
            executionCount += 1
        }
    }

    private actor IntentProbe {
        private(set) var intentWasDurableBeforeExecution = false

        func record(intentWasDurable: Bool) {
            intentWasDurableBeforeExecution = intentWasDurable
        }
    }

    private final class AsyncLatch: Sendable {
        private enum State: Sendable {
            case closed([CheckedContinuation<Void, Never>])
            case open
        }

        private let state = Mutex<State>(.closed([]))

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeImmediately = state.withLock { state in
                    switch state {
                    case var .closed(waiters):
                        waiters.append(continuation)
                        state = .closed(waiters)
                        return false
                    case .open:
                        return true
                    }
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }

        func open() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                switch state {
                case let .closed(waiters):
                    state = .open
                    return waiters
                case .open:
                    return []
                }
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private struct ProbeTool: Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- test tool observes an injected runtime repository (see docs/Concurrency/exception-manifest.md)
        let callName: String
        let result: String
        let executionProbe: ExecutionProbe?
        let intentProbe: IntentProbe?
        let repository: (any ThreadRuntimeRepository)?
        let turnID: UUID?

        var name: String { callName }
        let description = "A workspace dispatch test tool"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool { true }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            if let intentProbe, let repository, let turnID {
                let intents = try await repository.fetchToolIntents(turnID: turnID)
                await intentProbe.record(intentWasDurable: intents.contains { $0.toolCallID == "call-intent-order" })
            }
            await executionProbe?.recordExecution()
            return .success(result)
        }
    }

    private struct Environment {
        let manager: ThreadManager
        let router: ToolRouter
        let persistence: MockPersistenceService
        let bindings: InMemoryWorkspaceBindingRepository
        let repository: InMemoryThreadRuntimeRepository
        let threadID: UUID
        let workspace: WorkspaceReference
        let tool: ProbeTool
    }

    private func makeEnvironment(
        location: WorkspaceReference.WorkspaceLocation,
        toolName: String = "workspace_probe",
        tool: ProbeTool? = nil
    ) async throws -> Environment {
        let persistence = MockPersistenceService()
        let bindings = InMemoryWorkspaceBindingRepository()
        let repository = InMemoryThreadRuntimeRepository()
        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: bindings,
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .noWorkspace,
            workspaceCreator: MockWorkspaceCreator()
        )
        let router = ToolRouter(
            threadManager: manager,
            runtimeRepository: repository
        )
        let thread = try await manager.createThread(title: "Workspace dispatch")
        try await repository.saveThread(thread)

        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "workspace-dispatch", path: "/test"),
            location: location,
            tools: [.known(toolName)],
            rootPath: "/tmp"
        )
        try await persistence.saveWorkspace(workspace)
        try await manager.attachWorkspace(workspace.id, to: thread.id)

        let resolvedTool = tool ?? ProbeTool(
            callName: toolName,
            result: "workspace output",
            executionProbe: nil,
            intentProbe: nil,
            repository: nil,
            turnID: nil
        )
        guard let toolManager = await manager.getToolManager(for: thread.id) else {
            Issue.record("Thread tool manager was not created")
            return Environment(
                manager: manager,
                router: router,
                persistence: persistence,
                bindings: bindings,
                repository: repository,
                threadID: thread.id,
                workspace: workspace,
                tool: resolvedTool
            )
        }
        await toolManager.updateAvailableTools([resolvedTool.toAnyTool()])
        if let resolvedWorkspace = try await manager.workspaceResolver.workspace(id: workspace.id) {
            await toolManager.registerWorkspace(resolvedWorkspace)
        }

        return Environment(
            manager: manager,
            router: router,
            persistence: persistence,
            bindings: bindings,
            repository: repository,
            threadID: thread.id,
            workspace: workspace,
            tool: resolvedTool
        )
    }

    private func admit(_ environment: Environment, fingerprint: String) async throws -> UUID {
        let admission = try await environment.repository.admitTurn(
            threadID: environment.threadID,
            requestID: UUID(),
            callerIntentFingerprint: fingerprint
        )
        return admission.turn.identity.turnID
    }

    private func catalog(
        workspace: WorkspaceReference,
        tool: ProbeTool,
        isPrimary: Bool = false
    ) -> WorkspaceToolCatalog {
        WorkspaceToolCatalog(entries: [
            .init(
                workspace: workspace,
                label: workspace.uri.description,
                isPrimary: isPrimary,
                tools: [tool.toAnyTool()]
            ),
        ])
    }

    private static func handle(
        router: ToolRouter,
        threadID: UUID,
        turnID: UUID,
        calls: [ParsedToolCall],
        availableTools: [AnyTool],
        workspaceToolCatalog: WorkspaceToolCatalog
    ) async throws -> [TurnEvent] {
        let stream = AsyncThrowingStream<TurnEvent, Error> { continuation in
            Task {
                do {
                    _ = try await router.handlePendingToolCalls(
                        threadId: threadID,
                        turnID: turnID,
                        calls: calls,
                        availableTools: availableTools,
                        workspaceToolCatalog: workspaceToolCatalog,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        var events: [TurnEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    @Test("admission catalog remains stable after Workspace catalog and attachment changes")
    func admissionCatalogIsImmutable() async throws {
        let environment = try await makeEnvironment(location: .attached)
        _ = try await admit(environment, fingerprint: "catalog-snapshot")
        let captured = try await environment.manager.captureWorkspaceToolCatalog(
            for: environment.threadID,
            primaryWorkspaceID: nil
        )
        let capturedEntry = try #require(captured.entries.first)

        let replacement = WorkspaceReference(
            uri: WorkspaceURI(host: "workspace-dispatch", path: "/replacement"),
            location: .attached,
            tools: [.known("replacement_tool")],
            rootPath: "/tmp"
        )
        try await environment.persistence.saveWorkspace(environment.workspace.withTools([.known("replacement_tool")]))
        try await environment.persistence.saveWorkspace(replacement)
        try await environment.manager.detachWorkspace(environment.workspace.id, from: environment.threadID)
        try await environment.manager.attachWorkspace(replacement.id, to: environment.threadID)

        #expect(captured.entries.count == 1)
        #expect(capturedEntry.workspace.id == environment.workspace.id)
        #expect(capturedEntry.tools.map(\.callName) == [environment.tool.callName])
        let liveWorkspaces = try await environment.manager.getWorkspaces(for: environment.threadID)
        #expect(liveWorkspaces.attached.map(\.id) == [replacement.id])
    }

    @Test("ordinary binding is revalidated after waiting for the Workspace FIFO lane")
    func releasedBindingFailsBeforeSideEffectAfterLaneWait() async throws {
        let executionProbe = ExecutionProbe()
        let environment = try await makeEnvironment(
            location: .runtime,
            tool: ProbeTool(
                callName: "workspace_probe",
                result: "should not execute",
                executionProbe: executionProbe,
                intentProbe: nil,
                repository: nil,
                turnID: nil
            )
        )
        let turnID = try await admit(environment, fingerprint: "lane-revalidation")
        let catalog = catalog(workspace: environment.workspace, tool: environment.tool)
        let laneStarted = AsyncLatch()
        let releaseLane = AsyncLatch()
        let manager = environment.manager
        let workspaceID = environment.workspace.id
        let lane = Task {
            await manager.withWorkspaceExecution(workspaceID) {
                laneStarted.open()
                await releaseLane.wait()
            }
        }
        await laneStarted.wait()

        let call = ParsedToolCall(
            callId: "call-revalidated-after-wait",
            name: "call_tool",
            argumentsJSON: "{\"tool\":\"workspace_probe\",\"at\":\"\(environment.workspace.id.uuidString)\",\"arguments\":{}}"
        )
        let router = environment.router
        let threadID = environment.threadID
        let pending = Task {
            _ = try await Self.handle(
                router: router,
                threadID: threadID,
                turnID: turnID,
                calls: [call],
                availableTools: [catalog.callTool],
                workspaceToolCatalog: catalog
            )
        }

        for _ in 0 ..< 20 {
            let intents = try await environment.repository.fetchToolIntents(turnID: turnID)
            if intents.count == 1 { break }
            await Task.yield()
        }
        try await environment.bindings.release(
            workspaceID: environment.workspace.id,
            from: environment.threadID,
            now: Date()
        )
        releaseLane.open()
        await lane.value
        try await pending.value

        #expect(await executionProbe.executionCount == 0)
        let results = try await environment.repository.fetchToolResults(turnID: turnID)
        #expect(results.count == 1)
        #expect(results.first?.succeeded == false)
        #expect(results.first?.workspaceID == environment.workspace.id)
    }

    @Test("runtime and runtimeThread Workspace calls execute locally with route provenance")
    func localWorkspaceLocationsExecuteWithProvenance() async throws {
        let executionProbe = ExecutionProbe()
        let environment = try await makeEnvironment(location: .runtime, tool: ProbeTool(
            callName: "workspace_probe",
            result: "local output",
            executionProbe: executionProbe,
            intentProbe: nil,
            repository: nil,
            turnID: nil
        ))
        let secondWorkspace = WorkspaceReference(
            uri: WorkspaceURI(host: "workspace-dispatch", path: "/thread"),
            location: .runtimeThread,
            tools: [.known(environment.tool.callName)],
            rootPath: "/tmp"
        )
        try await environment.persistence.saveWorkspace(secondWorkspace)
        try await environment.manager.attachWorkspace(secondWorkspace.id, to: environment.threadID)
        let turnID = try await admit(environment, fingerprint: "local-provenance")
        let dispatchCatalog = WorkspaceToolCatalog(entries: [
            .init(workspace: environment.workspace, label: "runtime", isPrimary: false, tools: [environment.tool.toAnyTool()]),
            .init(workspace: secondWorkspace, label: "runtimeThread", isPrimary: false, tools: [environment.tool.toAnyTool()]),
        ])
        let calls = [
            ParsedToolCall(
                callId: "call-runtime",
                name: "call_tool",
                argumentsJSON: "{\"tool\":\"workspace_probe\",\"at\":\"\(environment.workspace.id.uuidString)\",\"arguments\":{}}"
            ),
            ParsedToolCall(
                callId: "call-runtime-thread",
                name: "call_tool",
                argumentsJSON: "{\"tool\":\"workspace_probe\",\"at\":\"\(secondWorkspace.id.uuidString)\",\"arguments\":{}}"
            ),
        ]
        _ = try await Self.handle(
            router: environment.router,
            threadID: environment.threadID,
            turnID: turnID,
            calls: calls,
            availableTools: [dispatchCatalog.callTool],
            workspaceToolCatalog: dispatchCatalog
        )

        #expect(await executionProbe.executionCount == 2)
        let results = try await environment.repository.fetchToolResults(turnID: turnID)
        #expect(Set(results.compactMap(\.workspaceID)) == Set([environment.workspace.id, secondWorkspace.id]))
        #expect(results.allSatisfy { $0.workspaceRouting == .explicit })
    }

    @Test("attached Workspace calls defer without runtime-side execution")
    func attachedWorkspaceDefersWithoutExecution() async throws {
        let executionProbe = ExecutionProbe()
        let environment = try await makeEnvironment(
            location: .attached,
            tool: ProbeTool(
                callName: "workspace_probe",
                result: "must remain external",
                executionProbe: executionProbe,
                intentProbe: nil,
                repository: nil,
                turnID: nil
            )
        )
        let turnID = try await admit(environment, fingerprint: "attached-deferral")
        let dispatchCatalog = catalog(workspace: environment.workspace, tool: environment.tool)
        let call = ParsedToolCall(
            callId: "call-attached",
            name: "call_tool",
            argumentsJSON: "{\"tool\":\"workspace_probe\",\"at\":\"\(environment.workspace.id.uuidString)\",\"arguments\":{}}"
        )
        _ = try await Self.handle(
            router: environment.router,
            threadID: environment.threadID,
            turnID: turnID,
            calls: [call],
            availableTools: [dispatchCatalog.callTool],
            workspaceToolCatalog: dispatchCatalog
        )

        #expect(await executionProbe.executionCount == 0)
        #expect(try await environment.repository.fetchToolResults(turnID: turnID).isEmpty)
        let intents = try await environment.repository.fetchToolIntents(turnID: turnID)
        #expect(intents.first?.workspaceID == environment.workspace.id)
    }

    @Test("Tool Intent is durable before the Workspace side effect")
    func intentPrecedesWorkspaceExecution() async throws {
        let intentProbe = IntentProbe()
        let environment = try await makeEnvironment(location: .runtime)
        let turnID = try await admit(environment, fingerprint: "intent-order")
        let tool = ProbeTool(
            callName: environment.tool.callName,
            result: "ordered",
            executionProbe: nil,
            intentProbe: intentProbe,
            repository: environment.repository,
            turnID: turnID
        )
        let dispatchCatalog = catalog(workspace: environment.workspace, tool: tool)
        let call = ParsedToolCall(
            callId: "call-intent-order",
            name: "call_tool",
            argumentsJSON: "{\"tool\":\"workspace_probe\",\"at\":\"\(environment.workspace.id.uuidString)\",\"arguments\":{}}"
        )
        _ = try await Self.handle(
            router: environment.router,
            threadID: environment.threadID,
            turnID: turnID,
            calls: [call],
            availableTools: [dispatchCatalog.callTool],
            workspaceToolCatalog: dispatchCatalog
        )

        #expect(await intentProbe.intentWasDurableBeforeExecution)
    }
}
