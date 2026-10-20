import Foundation
import JSONSchema
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

// `.serialized`: dispatch scenarios assert FIFO lane ordering through async latches with
// wall-clock waits. Serialization avoids timing interference between the scenarios
// (issue #155).
@Suite("Workspace tool dispatch integration", .serialized, .tags(.integration))
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

    /// Records concurrent entry into a Workspace's tools so a timeout overlap is observable.
    private actor OverlapProbe {
        private(set) var active = 0
        private(set) var maximumActive = 0
        private(set) var enterCount = 0
        private(set) var events: [String] = []

        func enter() -> Int {
            active += 1
            enterCount += 1
            maximumActive = max(maximumActive, active)
            events.append("enter-\(enterCount)")
            return enterCount
        }

        func leave(_ call: Int) {
            active -= 1
            events.append("leave-\(call)")
        }
    }

    /// A mutating Workspace tool that ignores cancellation and blocks until the test releases it.
    private struct CancellationIgnoringMutatingTool: PKTool {
        let callName: String
        let started: AsyncLatch
        let release: AsyncLatch
        let probe: OverlapProbe

        var name: String { callName }
        let toolDescription = "A cancellation-ignoring mutating Workspace tool"
        let requiresPermission = false
        let sideEffects: ToolSideEffects = .mutating
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool { true }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            let call = await probe.enter()
            if call == 1 {
                started.open()
            }
            await release.wait()
            await probe.leave(call)
            return .success("late")
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

    private struct ProbeTool: PKTool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- test tool observes an injected runtime repository (see docs/Concurrency/exception-manifest.md)
        let callName: String
        let result: String
        let executionProbe: ExecutionProbe?
        let intentProbe: IntentProbe?
        let repository: any TimelineRuntimeRepository?
        let turnID: UUID?

        var name: String { callName }
        let toolDescription = "A workspace dispatch test tool"
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

    private struct AliasedProbeTool: PKTool {
        let executionProbe: ExecutionProbe

        let callName = "native_tool"
        let name = "Friendly Native Tool"
        let toolDescription = "A native workspace tool with a display name"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool { true }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            await executionProbe.recordExecution()
            return .success("native output")
        }
    }

    private struct Environment {
        let manager: TimelineManager
        let router: ToolRouter
        let persistence: MockPersistenceService
        let bindings: InMemoryWorkspaceBindingRepository
        let repository: InMemoryTimelineRuntimeRepository
        let timelineID: UUID
        let workspace: WorkspaceReference
        let tool: AnyTool
    }

    private func makeEnvironment(
        location: WorkspaceReference.WorkspaceLocation,
        toolName: String = "workspace_probe",
        tool: AnyTool? = nil,
        toolExecutionTimeout: TimeInterval = 60,
        sleep: (@Sendable (UInt64) async throws -> Void)? = nil
    ) async throws -> Environment {
        let persistence = MockPersistenceService()
        let bindings = InMemoryWorkspaceBindingRepository()
        let repository = InMemoryTimelineRuntimeRepository()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: bindings,
                runtimeRepository: persistence
            ),
            workspaceProfile: .noWorkspace,
            workspaceCreator: MockWorkspaceCreator()
        )
        let router = ToolRouter(
            timelineManager: manager,
            runtimeRepository: repository,
            toolExecutionTimeout: toolExecutionTimeout,
            sleep: sleep
        )
        let timeline = try await manager.createTimeline(title: "Workspace dispatch")
        try await repository.saveTimeline(timeline)

        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "workspace-dispatch", path: "/test"),
            location: location,
            tools: [.known(toolName)],
            rootPath: "/tmp"
        )
        try await persistence.saveWorkspace(workspace)
        try await manager.attachWorkspace(workspace.id, to: timeline.id)

        let resolvedTool = tool ?? AnyTool(ProbeTool(
            callName: toolName,
            result: "workspace output",
            executionProbe: nil,
            intentProbe: nil,
            repository: nil,
            turnID: nil
        ))
        guard let toolManager = await manager.getToolManager(for: timeline.id) else {
            Issue.record("Timeline tool manager was not created")
            return Environment(
                manager: manager,
                router: router,
                persistence: persistence,
                bindings: bindings,
                repository: repository,
                timelineID: timeline.id,
                workspace: workspace,
                tool: resolvedTool
            )
        }
        await toolManager.updateAvailableTools([resolvedTool])
        if let resolvedWorkspace = try await manager.workspaceResolver.workspace(id: workspace.id) {
            await toolManager.registerWorkspace(resolvedWorkspace)
        }

        return Environment(
            manager: manager,
            router: router,
            persistence: persistence,
            bindings: bindings,
            repository: repository,
            timelineID: timeline.id,
            workspace: workspace,
            tool: resolvedTool
        )
    }

    private func admit(_ environment: Environment, fingerprint: String) async throws -> UUID {
        let admission = try await environment.repository.admitTurn(
            timelineID: environment.timelineID,
            requestID: UUID(),
            callerIntentFingerprint: fingerprint
        )
        return admission.turn.identity.turnID
    }

    private func catalog(
        workspace: WorkspaceReference,
        tool: AnyTool,
        isPrimary: Bool = false
    ) -> WorkspaceToolCatalog {
        WorkspaceToolCatalog(entries: [
            .init(
                workspace: workspace,
                label: workspace.uri.description,
                isPrimary: isPrimary,
                tools: [tool]
            ),
        ])
    }

    private func advertisedToolIDs(in tool: AnyTool) -> [String] {
        let schema = tool.parametersSchema.asDictionary
        let properties = schema["properties"]?.asDictionary ?? [:]
        let toolProperty = properties["tool"]?.asDictionary ?? [:]
        return toolProperty["enum"]?.asArray?.compactMap(\.asString) ?? []
    }

    private static func handle(
        router: ToolRouter,
        timelineID: UUID,
        turnID: UUID,
        calls: [ParsedToolCall],
        availableTools: [AnyTool],
        workspaceToolCatalog: WorkspaceToolCatalog
    ) async throws -> [TurnEvent] {
        let stream = AsyncThrowingStream<TurnEvent, Error> { continuation in
            Task {
                do {
                    _ = try await router.handlePendingToolCalls(
                        timelineId: timelineID,
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
            for: environment.timelineID,
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
        try await environment.manager.detachWorkspace(environment.workspace.id, from: environment.timelineID)
        try await environment.manager.attachWorkspace(replacement.id, to: environment.timelineID)

        #expect(captured.entries.count == 1)
        #expect(capturedEntry.workspace.id == environment.workspace.id)
        #expect(capturedEntry.tools.map(\.callName) == [environment.tool.callName])
        let liveWorkspaces = try await environment.manager.getWorkspaces(for: environment.timelineID)
        #expect(liveWorkspaces.attached.map(\.id) == [replacement.id])
    }

    @Test("ordinary binding is revalidated after waiting for the Workspace FIFO lane")
    func releasedBindingFailsBeforeSideEffectAfterLaneWait() async throws {
        let executionProbe = ExecutionProbe()
        let environment = try await makeEnvironment(
            location: .runtime,
            tool: AnyTool(ProbeTool(
                callName: "workspace_probe",
                result: "should not execute",
                executionProbe: executionProbe,
                intentProbe: nil,
                repository: nil,
                turnID: nil
            ))
        )
        let turnID = try await admit(environment, fingerprint: "lane-revalidation")
        let catalog = catalog(workspace: environment.workspace, tool: environment.tool)
        let laneStarted = AsyncLatch()
        let releaseLane = AsyncLatch()
        let manager = environment.manager
        let workspaceID = environment.workspace.id
        let lane = Task {
            try await manager.withWorkspaceExecution(workspaceID) {
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
        let timelineID = environment.timelineID
        let pending = Task {
            _ = try await Self.handle(
                router: router,
                timelineID: timelineID,
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
            from: environment.timelineID,
            now: Date()
        )
        releaseLane.open()
        try await lane.value
        try await pending.value

        #expect(await executionProbe.executionCount == 0)
        let results = try await environment.repository.fetchToolResults(turnID: turnID)
        #expect(results.count == 1)
        #expect(results.first?.isSuccessful == false)
        #expect(results.first?.workspaceID == environment.workspace.id)
    }

    @Test("runtime and runtimeTimeline Workspace calls execute locally with route provenance")
    func localWorkspaceLocationsExecuteWithProvenance() async throws {
        let executionProbe = ExecutionProbe()
        let environment = try await makeEnvironment(location: .runtime, tool: AnyTool(ProbeTool(
            callName: "workspace_probe",
            result: "local output",
            executionProbe: executionProbe,
            intentProbe: nil,
            repository: nil,
            turnID: nil
        )))
        let secondWorkspace = WorkspaceReference(
            uri: WorkspaceURI(host: "workspace-dispatch", path: "/timeline"),
            location: .runtimeTimeline,
            tools: [.known("workspace_probe_second")],
            rootPath: "/tmp"
        )
        try await environment.persistence.saveWorkspace(secondWorkspace)
        try await environment.manager.attachWorkspace(secondWorkspace.id, to: environment.timelineID)
        let turnID = try await admit(environment, fingerprint: "local-provenance")
        let secondTool = AnyTool(ProbeTool(
            callName: "workspace_probe_second",
            result: "second local output",
            executionProbe: executionProbe,
            intentProbe: nil,
            repository: nil,
            turnID: nil
        ))
        let dispatchCatalog = WorkspaceToolCatalog(entries: [
            .init(workspace: environment.workspace, label: "runtime", isPrimary: false, tools: [environment.tool]),
            .init(workspace: secondWorkspace, label: "runtimeTimeline", isPrimary: false, tools: [secondTool]),
        ])
        let calls = [
            ParsedToolCall(
                callId: "call-runtime",
                name: "call_tool",
                argumentsJSON: "{\"tool\":\"workspace_probe\",\"at\":\"\(environment.workspace.id.uuidString)\",\"arguments\":{}}"
            ),
            ParsedToolCall(
                callId: "call-runtime-timeline",
                name: "call_tool",
                argumentsJSON: "{\"tool\":\"workspace_probe_second\",\"at\":\"\(secondWorkspace.id.uuidString)\",\"arguments\":{}}"
            ),
        ]
        _ = try await Self.handle(
            router: environment.router,
            timelineID: environment.timelineID,
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
            tool: AnyTool(ProbeTool(
                callName: "workspace_probe",
                result: "must remain external",
                executionProbe: executionProbe,
                intentProbe: nil,
                repository: nil,
                turnID: nil
            ))
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
            timelineID: environment.timelineID,
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

    @Test("PKTool Intent is durable before the Workspace side effect")
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
        let dispatchCatalog = catalog(workspace: environment.workspace, tool: AnyTool(tool))
        let call = ParsedToolCall(
            callId: "call-intent-order",
            name: "call_tool",
            argumentsJSON: "{\"tool\":\"workspace_probe\",\"at\":\"\(environment.workspace.id.uuidString)\",\"arguments\":{}}"
        )
        _ = try await Self.handle(
            router: environment.router,
            timelineID: environment.timelineID,
            turnID: turnID,
            calls: [call],
            availableTools: [dispatchCatalog.callTool],
            workspaceToolCatalog: dispatchCatalog
        )

        #expect(await intentProbe.intentWasDurableBeforeExecution)
    }

    @Test("duplicate custom tool IDs are rejected, including with explicit Workspace routing")
    func duplicateWorkspaceToolIDsAreRejected() async throws {
        let persistence = MockPersistenceService()
        let bindings = InMemoryWorkspaceBindingRepository()
        let manager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                workspaceBindingRepository: bindings,
                runtimeRepository: persistence
            ),
            workspaceProfile: .noWorkspace,
            workspaceCreator: MockWorkspaceCreator()
        )
        let timeline = try await manager.createTimeline(title: "Duplicate tool IDs")

        let defA = ToolDefinition(id: "dup", name: "Dup A", description: "A", parametersSchema: [:])
        let defB = ToolDefinition(id: "dup", name: "Dup B", description: "B", parametersSchema: [:])
        let wsA = WorkspaceReference(
            uri: WorkspaceURI(host: "duplicate", path: "/a"),
            location: .runtime,
            tools: [.custom(defA)],
            rootPath: "/tmp"
        )
        let wsB = WorkspaceReference(
            uri: WorkspaceURI(host: "duplicate", path: "/b"),
            location: .runtime,
            tools: [.custom(defB)],
            rootPath: "/tmp"
        )
        try await persistence.saveWorkspace(wsA)
        try await persistence.saveWorkspace(wsB)
        try await manager.attachWorkspace(wsA.id, to: timeline.id)
        try await manager.attachWorkspace(wsB.id, to: timeline.id)

        let catalog = try await manager.captureWorkspaceToolCatalog(
            for: timeline.id,
            primaryWorkspaceID: nil
        )
        #expect(catalog.entries.count == 2)
        #expect(catalog.entries.allSatisfy { $0.tools.map(\.callName) == ["dup"] })
        #expect(catalog.isEmpty == false)
        #expect(catalog.callTool.parametersSchema.asDictionary["properties"]?.asDictionary?["tool"]?.asDictionary?["enum"]?.asArray?.isEmpty == true)

        let dispatcher = WorkspaceToolDispatcher(timelineManager: manager)
        let implicit = ParsedToolCall(
            callId: "call-implicit",
            name: WorkspaceToolDispatcher.callName,
            argumentsJSON: "{\"tool\":\"dup\",\"arguments\":{}}"
        )
        do {
            _ = try dispatcher.prepare(call: implicit, catalog: catalog)
            Issue.record("Duplicate identifiers must be rejected before dispatch")
        } catch let ToolError.ambiguousWorkspaceTool(tool, candidates) {
            #expect(tool == "dup")
            #expect(candidates.count == 2)
            #expect(candidates.map(\.workspaceID) == [wsA.id, wsB.id].sorted { $0.uuidString < $1.uuidString })
        } catch {
            Issue.record("Expected duplicate identifiers to be rejected as ambiguous, got \(error)")
        }

        let explicit = ParsedToolCall(
            callId: "call-explicit",
            name: WorkspaceToolDispatcher.callName,
            argumentsJSON: "{\"tool\":\"dup\",\"at\":\"\(wsB.id.uuidString)\",\"arguments\":{}}"
        )
        do {
            _ = try dispatcher.prepare(call: explicit, catalog: catalog)
            Issue.record("Explicit routing must not disambiguate duplicate identifiers")
        } catch let ToolError.ambiguousWorkspaceTool(tool, candidates) {
            #expect(tool == "dup")
            #expect(candidates.count == 2)
            #expect(candidates.map(\.workspaceID) == [wsA.id, wsB.id].sorted { $0.uuidString < $1.uuidString })
        } catch {
            Issue.record("Expected duplicate identifiers to be rejected as ambiguous, got \(error)")
        }
    }

    @Test("Workspace selectors advertise exact call names and reject display-name aliases")
    func workspaceSelectorsUseOnlyCapturedCallNames() async throws {
        let executionProbe = ExecutionProbe()
        let tool = AnyTool(AliasedProbeTool(executionProbe: executionProbe))
        let environment = try await makeEnvironment(
            location: .runtime,
            toolName: tool.callName,
            tool: tool
        )
        let turnID = try await admit(environment, fingerprint: "exact-workspace-selector")
        let dispatchCatalog = catalog(workspace: environment.workspace, tool: tool)

        #expect(advertisedToolIDs(in: dispatchCatalog.callTool) == ["native_tool"])

        let calls = [
            ParsedToolCall(
                callId: "call-display-alias",
                name: WorkspaceToolDispatcher.callName,
                argumentsJSON: "{\"tool\":\"Friendly Native Tool\",\"at\":\"\(environment.workspace.id.uuidString)\",\"arguments\":{}}"
            ),
            ParsedToolCall(
                callId: "call-exact-id",
                name: WorkspaceToolDispatcher.callName,
                argumentsJSON: "{\"tool\":\"native_tool\",\"at\":\"\(environment.workspace.id.uuidString)\",\"arguments\":{}}"
            ),
        ]
        _ = try await Self.handle(
            router: environment.router,
            timelineID: environment.timelineID,
            turnID: turnID,
            calls: calls,
            availableTools: [dispatchCatalog.callTool],
            workspaceToolCatalog: dispatchCatalog
        )

        #expect(await executionProbe.executionCount == 1)
        let results = try await environment.repository.fetchToolResults(turnID: turnID)
        #expect(results.count == 2)
        #expect(results.first(where: { $0.toolCallID == "call-display-alias" })?.isSuccessful == false)
        #expect(results.first(where: { $0.toolCallID == "call-exact-id" })?.isSuccessful == true)
    }

    @Test("explicit Workspace routing cannot select an identifier outside the captured catalog")
    func explicitWorkspaceCannotSelectUncapturedTool() async throws {
        let environment = try await makeEnvironment(location: .runtime)
        let otherWorkspace = WorkspaceReference(
            uri: WorkspaceURI(host: "workspace-dispatch", path: "/other"),
            location: .runtime,
            tools: [.known("different_tool")],
            rootPath: "/tmp"
        )
        let dispatchCatalog = WorkspaceToolCatalog(entries: [
            .init(workspace: environment.workspace, label: "captured", isPrimary: false, tools: [environment.tool]),
            .init(workspace: otherWorkspace, label: "other", isPrimary: false, tools: []),
        ])
        let call = ParsedToolCall(
            callId: "call-outside-catalog",
            name: WorkspaceToolDispatcher.callName,
            argumentsJSON: "{\"tool\":\"different_tool\",\"at\":\"\(otherWorkspace.id.uuidString)\",\"arguments\":{}}"
        )
        let dispatcher = WorkspaceToolDispatcher(timelineManager: environment.manager)

        #expect(throws: ToolError.toolNotFound("different_tool")) {
            _ = try dispatcher.prepare(call: call, catalog: dispatchCatalog)
        }
    }

    @Test("mutating timeout holds the Workspace lane until the abandoned tool ends")
    func mutatingTimeoutHoldsLaneUntilAbandonedToolEnds() async throws {
        let probe = OverlapProbe()
        let started = AsyncLatch()
        let release = AsyncLatch()
        let tool = CancellationIgnoringMutatingTool(
            callName: "workspace_probe",
            started: started,
            release: release,
            probe: probe
        )
        // The first call times out only after its mutating tool has started. Later calls park so
        // the second tool wins its own race and completes normally once the lane is free.
        let timeoutCalls = Mutex(0)
        let sleep: @Sendable (UInt64) async throws -> Void = { _ in
            let call = timeoutCalls.withLock { count -> Int in
                count += 1
                return count
            }
            if call == 1 {
                await started.wait()
            } else {
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let environment = try await makeEnvironment(
            location: .runtime,
            tool: AnyTool(tool),
            toolExecutionTimeout: 0.1,
            sleep: sleep
        )
        let turnID = try await admit(environment, fingerprint: "mutating-timeout-lane-hold")
        let dispatchCatalog = catalog(workspace: environment.workspace, tool: environment.tool)
        let firstCall = ParsedToolCall(
            callId: "call-timeout-first",
            name: "call_tool",
            argumentsJSON: "{\"tool\":\"workspace_probe\",\"at\":\"\(environment.workspace.id.uuidString)\",\"arguments\":{}}"
        )
        let secondCall = ParsedToolCall(
            callId: "call-timeout-second",
            name: "call_tool",
            argumentsJSON: "{\"tool\":\"workspace_probe\",\"at\":\"\(environment.workspace.id.uuidString)\",\"arguments\":{}}"
        )

        let first = Task {
            try await Self.handle(
                router: environment.router,
                timelineID: environment.timelineID,
                turnID: turnID,
                calls: [firstCall],
                availableTools: [dispatchCatalog.callTool],
                workspaceToolCatalog: dispatchCatalog
            )
        }
        await started.wait()
        _ = try await first.value

        // The timed-out operation returned, but the abandoned mutating tool is still running, so
        // the lane must stay closed. Without the hold this is already false and the second call
        // below would overlap the first tool.
        #expect(environment.manager.isWorkspaceBusy(environment.workspace.id))

        let second = Task {
            try await Self.handle(
                router: environment.router,
                timelineID: environment.timelineID,
                turnID: turnID,
                calls: [secondCall],
                availableTools: [dispatchCatalog.callTool],
                workspaceToolCatalog: dispatchCatalog
            )
        }

        // Wait until the second call's durable intent is recorded; the dispatcher enters the lane
        // immediately after that write. Then give an unheld lane a bounded window to overlap.
        var secondIntentRecorded = false
        for _ in 0..<1000 {
            if try await environment.repository.fetchToolIntents(turnID: turnID)
                .contains(where: { $0.toolCallID == secondCall.callId }) {
                secondIntentRecorded = true
                break
            }
            await Task.yield()
        }
        #expect(secondIntentRecorded)
        let deadline = ContinuousClock.now + .milliseconds(500)
        while await probe.enterCount < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await probe.maximumActive == 1)

        release.open()
        _ = try await second.value

        #expect(await probe.events == ["enter-1", "leave-1", "enter-2", "leave-2"])
        #expect(await probe.maximumActive == 1)
    }

    @Test("cancelled mutating call holds the Workspace lane until the abandoned tool ends (#367)")
    func cancelledMutationHoldsLaneUntilAbandonedToolEnds() async throws {
        // Regression for #367: the timeout path hands a still-running mutating tool to the lane,
        // but the cancellation path used to finish the race without that handoff. The lane then
        // released and a second mutation could overlap the first. This drives the real
        // `ToolTimeoutEnforcer` + `TimelineManager` lane wiring and cancels the first caller.
        let probe = OverlapProbe()
        let started = AsyncLatch()
        let release = AsyncLatch()
        let tool = AnyTool(CancellationIgnoringMutatingTool(
            callName: "workspace_probe",
            started: started,
            release: release,
            probe: probe
        ))
        let environment = try await makeEnvironment(location: .runtime, tool: tool)
        let manager = environment.manager
        let workspaceID = environment.workspace.id
        let parkedSleep: @Sendable (UInt64) async throws -> Void = { _ in
            try await Task.sleep(for: .seconds(3600))
        }

        let first = Task {
            try await manager.withWorkspaceExecution(workspaceID) {
                try await ToolTimeoutEnforcer.execute(
                    tool,
                    arguments: [:],
                    timeout: 60,
                    sleep: parkedSleep,
                    onAbandon: { task in
                        manager.retainWorkspaceLane(workspaceID, until: task)
                    }
                )
            }
        }
        await started.wait()
        first.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }

        // The cancelled operation returned, but the cancellation-ignoring mutation is still
        // running, so the lane must stay held rather than released to the next caller.
        #expect(manager.isWorkspaceBusy(workspaceID))

        let second = Task {
            try await manager.withWorkspaceExecution(workspaceID) {
                try await ToolTimeoutEnforcer.execute(
                    tool,
                    arguments: [:],
                    timeout: 60,
                    sleep: parkedSleep
                )
            }
        }

        // With the lane held, the second mutation cannot enter during a bounded window. Without
        // the cancellation handoff the lane is already open and it enters here.
        let deadline = ContinuousClock.now + .milliseconds(500)
        while await probe.enterCount < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await probe.maximumActive == 1)
        #expect(await probe.enterCount == 1)

        // Releasing the first tool lets the held lane drain and the second mutation resume.
        release.open()
        _ = try await second.value

        #expect(await probe.events == ["enter-1", "leave-1", "enter-2", "leave-2"])
        #expect(await probe.maximumActive == 1)
        #expect(manager.isWorkspaceBusy(workspaceID) == false)
    }
}
