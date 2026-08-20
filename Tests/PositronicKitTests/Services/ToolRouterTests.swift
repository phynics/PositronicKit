import Foundation
import Logging
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Synchronization
import Testing

/// A one-shot asynchronous latch. Waiting uses a continuation, so task cancellation does not
/// resume a waiter; `open()` deterministically resumes every current and future waiter.
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

private func captureProjectedToolEvents(
    _ body: @Sendable @escaping (AsyncThrowingStream<TurnEvent, Error>.Continuation) async throws -> Void
) async throws -> [TurnEvent] {
    var events: [TurnEvent] = []
    let stream = AsyncThrowingStream<TurnEvent, Error> { continuation in
        Task {
            do {
                try await body(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    for try await event in stream {
        events.append(event)
    }
    return events
}

/// Variant of `captureProjectedToolEvents` that returns the body's result, draining (and discarding)
/// the projected event stream so the body runs to completion.
private actor ResultHolder<R: Sendable> { // swiftlint:disable:this concurrency_reference_box_naming -- actor-based test double (see docs/Concurrency/exception-manifest.md)
    var value: R?
    func set(_ newValue: R) {
        value = newValue
    }
}

private func captureProjectedToolEventsResult<R: Sendable>(
    _ body: @Sendable @escaping (AsyncThrowingStream<TurnEvent, Error>.Continuation) async throws -> R
) async throws -> R {
    let holder = ResultHolder<R>()
    let stream = AsyncThrowingStream<TurnEvent, Error> { continuation in
        Task {
            do {
                let value = try await body(continuation)
                await holder.set(value)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    for try await _ in stream {}
    return try #require(await holder.value)
}

final class ToolRouterTests {
    struct MockTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName: String
        let name: String
        let description = "A mock tool for testing"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        var result: ToolResult

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            if !result.success, result.error == "client_tools_disallowed_on_private_thread" {
                throw ToolError.attachedToolsDisallowedOnPrivateThread
            }
            return result
        }
    }

    /// A permissioned tool that records whether its body ever ran, so a test can assert that an
    /// un-approved call is blocked *before* execution rather than merely failing afterwards.
    final class PermissionedTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName: String
        let name: String
        let description = "A permissioned mock tool"
        let requiresPermission = true
        private(set) var didExecute = false
        let parametersSchema = makeEmptyObjectSchema()

        init(id: String) {
            self.callName = id
            name = id
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            didExecute = true
            return .success("executed")
        }
    }

    /// Records every gate consultation so a test can assert the gate was actually reached.
    final class RecordingGate: ToolApprovalPolicy, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let decision: ToolApprovalDecision
        private(set) var consultedToolIds: [String] = []

        init(decision: ToolApprovalDecision) {
            self.decision = decision
        }

        func requestApproval(tool: AnyTool, arguments _: [String: AnyCodable]) async -> ToolApprovalDecision {
            consultedToolIds.append(tool.callName)
            return decision
        }
    }

    /// Builds a thread with a single registered tool and returns the router under test.
    private func setupRouter(
        with tool: any PKContracts.Tool,
        approvalPolicy: any ToolApprovalPolicy,
        disabledToolIDs: Set<String> = [],
        runtimeRepository: (any ThreadRuntimeRepository)? = nil
    ) async throws -> (ToolRouter, UUID, MockPersistenceService) {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            messageStore: mockPersistence,
            runtimeRepository: runtimeRepository,
            approvalPolicy: approvalPolicy
        )

        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(tool.callName))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        await toolManager?.updateAvailableTools([tool.toAnyTool()])

        for toolID in disabledToolIDs {
            _ = await threadManager.disableTool(id: toolID, for: session.id)
        }

        return (toolRouter, session.id, mockPersistence)
    }

    @Test("A permissioned tool is not executed when the approval gate denies it (structured call path)")
    func permissionedToolBlockedWhenDenied() async throws {
        let tool = PermissionedTool(id: "needs_permission")
        let gate = RecordingGate(decision: .deny)
        let (router, threadID, _) = try await setupRouter(with: tool, approvalPolicy: gate)

        do {
            _ = try await router.execute(
                tool: .known("needs_permission"),
                arguments: [:],
                threadID: threadID
            )
            Issue.record("Expected permissionDenied to be thrown")
        } catch ToolError.permissionDenied("needs_permission") {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(tool.didExecute == false)
        #expect(gate.consultedToolIds == ["needs_permission"])
    }

    @Test("A permissioned tool executes once the approval gate approves it")
    func permissionedToolRunsWhenApproved() async throws {
        let tool = PermissionedTool(id: "needs_permission")
        let gate = RecordingGate(decision: .approve)
        let (router, threadID, _) = try await setupRouter(with: tool, approvalPolicy: gate)

        let result = try await router.execute(
            tool: .known("needs_permission"),
            arguments: [:],
            threadID: threadID
        )

        guard case let .completed(output) = result else {
            Issue.record("Expected .completed outcome, got \(result)")
            return
        }
        #expect(output == "executed")
        #expect(tool.didExecute == true)
        #expect(gate.consultedToolIds == ["needs_permission"])
    }

    @Test("Text-fallback tool calls follow the same approval gate as structured calls (YAK-31)")
    func textFallbackToolCallBlockedWhenDenied() async throws {
        let tool = PermissionedTool(id: "needs_permission")
        let gate = RecordingGate(decision: .deny)
        let (router, threadID, _) = try await setupRouter(with: tool, approvalPolicy: gate)

        // A fallback-parsed call arrives as a ParsedToolCall through handlePendingToolCalls, the same
        // entry point the text-fallback path feeds. A denied permissioned tool must be projected as a
        // tool error and never executed.
        let call = ParsedToolCall(callId: "call-fallback", name: "needs_permission", argumentsJSON: "{}")
        let result = try await captureProjectedToolEventsResult { continuation in
            try await router.handlePendingToolCalls(
                threadId: threadID,
                calls: [call],
                availableTools: [],
                continuation: continuation
            )
        }

        #expect(tool.didExecute == false)
        #expect(result.hasDeferred == false)
        #expect(result.resolvedToolParams.first?.content.contains("permission") == true)
    }

    @Test("Workspace call_tool ambiguity returns a rich correction without execution")
    func workspaceCallToolAmbiguity() async throws {
        let tool = MockTool(callName: "read_file", result: .success("workspace output"))
        let runtimeRepository = InMemoryThreadRuntimeRepository()
        let (router, threadID, persistence) = try await setupRouter(
            with: tool,
            approvalPolicy: DenyAllToolApprovalPolicy(),
            runtimeRepository: runtimeRepository
        )
        try await runtimeRepository.saveThread(Thread(id: threadID))
        let admission = try await runtimeRepository.admitTurn(
            threadID: threadID,
            requestID: UUID(),
            callerIntentFingerprint: "workspace-ambiguity"
        )
        let turnID = admission.turn.identity.turnID
        let first = try #require(persistence.workspaces.first)
        let second = WorkspaceReference(
            id: UUID(),
            uri: WorkspaceURI(host: "pk-runtime", path: "/second"),
            location: .runtime,
            tools: [.known(tool.callName)]
        )
        try await persistence.saveWorkspace(second)
        try await persistence.addToolToWorkspace(workspaceId: second.id, tool: .known(tool.callName))

        let catalog = WorkspaceToolCatalog(entries: [
            .init(workspace: first, label: first.uri.description, isPrimary: false, tools: [tool.toAnyTool()]),
            .init(workspace: second, label: second.uri.description, isPrimary: false, tools: [tool.toAnyTool()]),
        ])
        // Ambiguity must not execute either candidate or require a live binding.
        let ambiguousCall = ParsedToolCall(
            callId: "call-ambiguous",
            name: "call_tool",
            argumentsJSON: "{\"tool\":\"read_file\",\"arguments\":{}}"
        )
        let result = try await captureProjectedToolEventsResult { continuation in
            try await router.handlePendingToolCalls(
                threadId: threadID,
                turnID: turnID,
                calls: [ambiguousCall],
                availableTools: [catalog.callTool],
                workspaceToolCatalog: catalog,
                continuation: continuation
            )
        }

        #expect(result.hasDeferred == false)
        #expect(result.resolvedToolParams.first?.content.contains("call_tool") == true)
        #expect(result.resolvedToolParams.first?.content.contains(first.id.uuidString) == true)
        #expect(result.resolvedToolParams.first?.content.contains(second.id.uuidString) == true)
        #expect(tool.result.output == "workspace output")
        let notices = try await runtimeRepository.fetchNotices(turnID: turnID)
        #expect(notices.contains(where: {
            $0.kind == "ambiguousWorkspaceTool"
                && ($0.message ?? "").contains(first.id.uuidString)
                && ($0.message ?? "").contains(second.id.uuidString)
        }))
    }

    @Test("Workspace call_tool success executes the selected workspace and records provenance")
    func workspaceCallToolSuccessProvenance() async throws {
        let tool = MockTool(callName: "read_file", result: .success("workspace output"))
        let runtimeRepository = InMemoryThreadRuntimeRepository()
        let (router, threadID, persistence) = try await setupRouter(
            with: tool,
            approvalPolicy: DenyAllToolApprovalPolicy(),
            runtimeRepository: runtimeRepository
        )
        try await runtimeRepository.saveThread(Thread(id: threadID))
        let admission = try await runtimeRepository.admitTurn(
            threadID: threadID,
            requestID: UUID(),
            callerIntentFingerprint: "workspace-success"
        )
        let turnID = admission.turn.identity.turnID
        let workspace = try #require(persistence.workspaces.first)
        let catalog = WorkspaceToolCatalog(entries: [
            .init(workspace: workspace, label: workspace.uri.description, isPrimary: false, tools: [tool.toAnyTool()]),
        ])
        let call = ParsedToolCall(
            callId: "call-success",
            name: "call_tool",
            argumentsJSON: "{\"tool\":\"read_file\",\"at\":\"\(workspace.id.uuidString)\",\"arguments\":{}}"
        )
        let events = try await captureProjectedToolEvents { continuation in
            _ = try await router.handlePendingToolCalls(
                threadId: threadID,
                turnID: turnID,
                calls: [call],
                availableTools: [catalog.callTool],
                workspaceToolCatalog: catalog,
                continuation: continuation
            )
        }

        #expect(events.contains(where: {
            guard case let .completion(.toolExecution(toolCallID: id, status: status)) = $0 else { return false }
            guard id == "call-success", case let .success(result) = status else { return false }
            return result.success && result.workspaceID == workspace.id && result.workspaceRouting == .explicit
        }))
        let results = try await runtimeRepository.fetchToolResults(turnID: turnID)
        #expect(results.first?.succeeded == true)
        #expect(results.first?.workspaceID == workspace.id)
        #expect(results.first?.workspaceRouting == .explicit)
    }

    @Test("Workspace call_tool failures retain route provenance in events and records")
    func workspaceCallToolFailureProvenance() async throws {
        let tool = MockTool(callName: "read_file", result: .failure("workspace failed"))
        let runtimeRepository = InMemoryThreadRuntimeRepository()
        let (router, threadID, persistence) = try await setupRouter(
            with: tool,
            approvalPolicy: DenyAllToolApprovalPolicy(),
            runtimeRepository: runtimeRepository
        )
        try await runtimeRepository.saveThread(Thread(id: threadID))
        let admission = try await runtimeRepository.admitTurn(
            threadID: threadID,
            requestID: UUID(),
            callerIntentFingerprint: "workspace-failure"
        )
        let turnID = admission.turn.identity.turnID
        let workspace = try #require(persistence.workspaces.first)
        let catalog = WorkspaceToolCatalog(entries: [
            .init(workspace: workspace, label: workspace.uri.description, isPrimary: false, tools: [tool.toAnyTool()]),
        ])
        let call = ParsedToolCall(
            callId: "call-failure",
            name: "call_tool",
            argumentsJSON: "{\"tool\":\"read_file\",\"at\":\"\(workspace.id.uuidString)\",\"arguments\":{}}"
        )
        let events = try await captureProjectedToolEvents { continuation in
            _ = try await router.handlePendingToolCalls(
                threadId: threadID,
                turnID: turnID,
                calls: [call],
                availableTools: [catalog.callTool],
                workspaceToolCatalog: catalog,
                continuation: continuation
            )
        }

        #expect(events.contains(where: {
            guard case let .completion(.toolExecution(toolCallID: id, status: status)) = $0 else { return false }
            guard id == "call-failure" else { return false }
            guard case let .workspaceFailed(_, _, workspaceID, routing) = status else { return false }
            return workspaceID == workspace.id && routing == .explicit
        }))
        let results = try await runtimeRepository.fetchToolResults(turnID: turnID)
        #expect(results.first?.workspaceID == workspace.id)
        #expect(results.first?.workspaceRouting == .explicit)
    }

    @Test("A disabled tool is rejected at the execution sink and projected as a failure")
    func disabledToolIsRejectedAtExecutionSink() async throws {
        let tool = PermissionedTool(id: "disabled_tool")
        let gate = RecordingGate(decision: .approve)
        let (router, threadID, persistence) = try await setupRouter(
            with: tool,
            approvalPolicy: gate,
            disabledToolIDs: ["disabled_tool"]
        )

        let call = ParsedToolCall(callId: "call-disabled", name: "disabled_tool", argumentsJSON: "{}")
        let events = try await captureProjectedToolEvents { continuation in
            let result = try await router.handlePendingToolCalls(
                threadId: threadID,
                calls: [call],
                availableTools: [],
                continuation: continuation
            )

            #expect(result.hasDeferred == false)
            #expect(result.resolvedToolParams.count == 1)
            #expect(result.resolvedToolParams.first?.content.contains("could not be found") == true)
        }

        #expect(tool.didExecute == false)
        #expect(gate.consultedToolIds.isEmpty)
        #expect(persistence.messages.count == 1)
        #expect(persistence.messages.first?.content.contains("could not be found") == true)
        #expect(events.contains(where: {
            if case let .completion(event) = $0,
               case let .toolExecution(toolCallId, status) = event,
               case .failed = status
            {
                return toolCallId == "call-disabled"
            }
            return false
        }))
        #expect(!events.contains(where: {
            if case let .completion(event) = $0,
               case let .toolExecution(toolCallId, status) = event,
               case .success = status
            {
                return toolCallId == "call-disabled"
            }
            return false
        }))
    }

    @Test("A dynamic tool cannot bypass a disabled registered call name")
    func dynamicToolCannotBypassDisabledCallName() async throws {
        let registeredTool = PermissionedTool(id: "collision")
        let dynamicTool = PermissionedTool(id: "collision")
        let gate = RecordingGate(decision: .approve)
        let (router, threadID, _) = try await setupRouter(
            with: registeredTool,
            approvalPolicy: gate,
            disabledToolIDs: ["collision"]
        )

        do {
            _ = try await router.execute(
                tool: .known("collision"),
                arguments: [:],
                threadID: threadID,
                availableTools: [dynamicTool.toAnyTool()]
            )
            Issue.record("Expected toolNotFound for a disabled call name")
        } catch ToolError.toolNotFound("collision") {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(registeredTool.didExecute == false)
        #expect(dynamicTool.didExecute == false)
        #expect(gate.consultedToolIds.isEmpty)
    }

    @Test("A non-permissioned tool executes without consulting the approval gate (regression)")
    func nonPermissionedToolBypassesGate() async throws {
        let tool = MockTool(callName: "free_tool", name: "free_tool", result: .success("free output"))
        // A deny-all gate must not affect non-permissioned tools.
        let gate = RecordingGate(decision: .deny)
        let (router, threadID, _) = try await setupRouter(with: tool, approvalPolicy: gate)

        let result = try await router.execute(
            tool: .known("free_tool"),
            arguments: [:],
            threadID: threadID
        )

        guard case let .completed(output) = result else {
            Issue.record("Expected .completed outcome, got \(result)")
            return
        }
        #expect(output == "free output")
        #expect(gate.consultedToolIds.isEmpty)
    }

    struct NeverFinishingTool: PKContracts.Tool {
        let callName = "never_finishes"
        let name = "never_finishes"
        let description = "A tool that never finishes unless cancelled"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            try await Task.sleep(for: .seconds(60))
            return .success("late")
        }
    }

    /// A tool that suspends asynchronously and ignores cooperative cancellation until released.
    private struct UncooperativeTool: PKContracts.Tool {
        let callName = "uncooperative"
        let name = "uncooperative"
        let description = "A tool that suspends and ignores cancellation"
        let requiresPermission = false
        let started: AsyncLatch
        let release: AsyncLatch
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            started.open()
            await release.wait()
            return .success("late")
        }
    }

    private func setupThreadManager() async throws -> (ThreadManager, MockPersistenceService) {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceRoot: workspace.root
        )
        return (threadManager, mockPersistence)
    }

    @Test

    func executeLocally() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        // Setup session and local workspace
        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "pk://local")), location: .runtime, originID: nil)

        // Mock persistence expects WorkspaceReference
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)

        // Setup internal tools by extracting the ToolManager
        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)

        let toolId = "local_tool"
        let mockTool = MockTool(callName: toolId, name: toolId, result: .success("Local success"))
        await toolManager?.updateAvailableTools([mockTool.toAnyTool()])

        // The mock persistence doesn't automatically wire tool IDs to workspaces for `findWorkspaceForTool`
        // We simulate `addToolToWorkspace` or just rely on the tool manager falling back to the candidates.
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(toolId))

        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = ["param": AnyCodable("value")]

        let result = try await toolRouter.execute(tool: toolRef, arguments: arguments, threadID: session.id)
        guard case let .completed(output) = result else {
            Issue.record("Expected .completed outcome")
            return
        }
        #expect(output == "Local success")
    }

    @Test

    func attachedWorkspaceToolDefersExternalExecution() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        let session = try await threadManager.createThread()
        let workspaceId = UUID()

        // Setup attached workspace
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "pk://remote")), location: .attached, originID: UUID())
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)

        let toolId = "attached_tool"
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(toolId))

        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = [:]

        do {
            let result = try await toolRouter.execute(tool: toolRef, arguments: arguments, threadID: session.id)
            guard case .deferredExternally = result else {
                Issue.record("Expected .deferredExternally")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test

    func attachedWorkspaceToolWithoutOriginStillDefers() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        let session = try await threadManager.createThread()
        let workspaceId = UUID()

        // Setup attached workspace missing an originId
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "pk://remote")), location: .attached, originID: nil)
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)

        let toolId = "attached_tool"
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(toolId))

        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = [:]

        do {
            let result = try await toolRouter.execute(tool: toolRef, arguments: arguments, threadID: session.id)
            guard case .deferredExternally = result else {
                Issue.record("Expected .deferredExternally")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A dynamic per-turn tool (passed via availableTools) executes locally even when the thread has no attached workspace at all (YAK-19)")
    func dynamicToolExecutesWithoutAnyWorkspace() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        // A freshly created thread still gets its own runtime workspace from `createThread`,
        // so to reproduce "no workspace at all" we must detach it — mirroring a thread that
        // never had a folder attached and exercises only workspace-independent demo tools like
        // `calculator`/`current_datetime`.
        let session = try await threadManager.createThread()
        for attachedId in session.attachedWorkspaceIDs {
            try await threadManager.detachWorkspace(attachedId, from: session.id)
        }
        let workspaces = try await threadManager.getWorkspaces(for: session.id)
        #expect(workspaces.primary == nil)
        #expect(workspaces.attached.isEmpty == true)

        let toolId = "dynamic_demo_tool"
        let dynamicTool = MockTool(callName: toolId, name: toolId, result: .success("dynamic success"))
        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = [:]

        let result = try await toolRouter.execute(
            tool: toolRef,
            arguments: arguments,
            threadID: session.id,
            availableTools: [dynamicTool.toAnyTool()]
        )

        guard case let .completed(output) = result else {
            Issue.record("Expected .completed outcome, got \(result)")
            return
        }
        #expect(output == "dynamic success")
    }

    @Test

    func executeToolNotFound() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        let session = try await threadManager.createThread()
        let toolRef = ToolReference.known("unknown")
        let arguments: [String: AnyCodable] = [:]

        do {
            _ = try await toolRouter.execute(tool: toolRef, arguments: arguments, threadID: session.id)
            Issue.record("Should have thrown toolNotFound")
        } catch ToolError.toolNotFound {
            // Expected
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }
    }

    @Test("Explicit invalid workspaceID fails closed with workspaceNotFound (YAK-33)")
    func explicitInvalidWorkspaceIDFailsClosed() async throws {
        let tool = MockTool(callName: "test_tool", name: "test_tool", result: .success("success"))
        let gate = RecordingGate(decision: .deny)
        let (router, threadID, _) = try await setupRouter(with: tool, approvalPolicy: gate)

        let invalidWorkspaceId = UUID()
        let arguments: [String: AnyCodable] = ["workspaceID": AnyCodable(invalidWorkspaceId.uuidString)]

        do {
            _ = try await router.execute(
                tool: .known("test_tool"),
                arguments: arguments,
                threadID: threadID
            )
            Issue.record("Expected workspaceNotFound to be thrown")
        } catch let ToolError.workspaceNotFound(thrownId) {
            #expect(thrownId == invalidWorkspaceId)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Well-formed but unattached explicit workspaceID fails closed (YAK-33)")
    func unattachedExplicitWorkspaceIDFailsClosed() async throws {
        let tool = MockTool(callName: "test_tool", name: "test_tool", result: .success("success"))
        let gate = RecordingGate(decision: .deny)
        let (router, threadID, _) = try await setupRouter(with: tool, approvalPolicy: gate)

        // Create a valid UUID that is definitely not attached to this thread
        let unattachedWorkspaceId = UUID()
        let arguments: [String: AnyCodable] = ["workspaceID": AnyCodable(unattachedWorkspaceId.uuidString)]

        do {
            _ = try await router.execute(
                tool: .known("test_tool"),
                arguments: arguments,
                threadID: threadID
            )
            Issue.record("Expected workspaceNotFound to be thrown for unattached workspace")
        } catch let ToolError.workspaceNotFound(thrownId) {
            #expect(thrownId == unattachedWorkspaceId)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Omitted workspaceID still uses default workspace resolution (YAK-33 regression guard)")
    func omittedWorkspaceIDUsesDefaultResolution() async throws {
        let tool = MockTool(callName: "test_tool", name: "test_tool", result: .success("default workspace success"))
        let gate = RecordingGate(decision: .deny)
        let (router, threadID, _) = try await setupRouter(with: tool, approvalPolicy: gate)

        // No workspaceID in arguments — should proceed with normal default resolution
        let arguments: [String: AnyCodable] = [:]

        let result = try await router.execute(
            tool: .known("test_tool"),
            arguments: arguments,
            threadID: threadID
        )

        guard case let .completed(output) = result else {
            Issue.record("Expected .completed outcome, got \(result)")
            return
        }
        #expect(output == "default workspace success")
    }

    @Test("Local tool execution timeout is projected as a tool error")
    func localToolExecutionTimeoutIsProjectedAsToolError() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            messageStore: mockPersistence,
            toolExecutionTimeout: 0.01
        )

        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("never_finishes"))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        await toolManager?.updateAvailableTools([NeverFinishingTool().toAnyTool()])

        let call = ParsedToolCall(callId: "call-timeout", name: "never_finishes", argumentsJSON: "{}")
        let events = try await captureProjectedToolEvents { continuation in
            let result = try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call],
                availableTools: [],
                continuation: continuation
            )

            #expect(result.hasDeferred == false)
            #expect(result.resolvedToolParams.count == 1)
            #expect(result.resolvedToolParams.first?.content.contains("Tool execution timed out after 0.01 seconds") == true)
        }

        #expect(mockPersistence.messages.count == 1)
        #expect(mockPersistence.messages.first?.content.contains("Tool execution timed out after 0.01 seconds") == true)
        #expect(events.contains(where: {
            if case let .completion(event) = $0,
               case let .toolExecution(toolCallId, status) = event,
               case .failed = status
            {
                return toolCallId == "call-timeout"
            }
            return false
        }))
    }

    @Test("Timeout wins even for tools that ignore cancellation")
    func timeoutBoundsUncooperativeTool() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let started = AsyncLatch()
        let release = AsyncLatch()
        defer { release.open() }

        let toolRouter = ToolRouter(
            threadManager: threadManager,
            messageStore: mockPersistence,
            toolExecutionTimeout: 60,
            sleep: { _ in await started.wait() }
        )

        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("uncooperative"))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        await toolManager?.updateAvailableTools([
            UncooperativeTool(started: started, release: release).toAnyTool(),
        ])

        let call = ParsedToolCall(callId: "call-timeout", name: "uncooperative", argumentsJSON: "{}")

        let result = try await captureProjectedToolEventsResult { continuation in
            try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call],
                availableTools: [],
                continuation: continuation
            )
        }
        #expect(result.hasDeferred == false)
        #expect(result.resolvedToolParams.first?.content.contains("timed out") == true)
    }
}

// MARK: - Recasted workspace-resolution edge-case tests (formerly ToolRoutingDecision isolation tests)

struct ToolRouterWorkspaceResolutionTests {
    private func setupThreadManager() async throws -> (ThreadManager, MockPersistenceService) {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceRoot: workspace.root
        )
        return (threadManager, mockPersistence)
    }

    @Test("Malformed workspaceID string (not a UUID) fails closed with invalidWorkspaceID (PKRR-015)")
    func malformedWorkspaceIDFailsClosed() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("cat"))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        let mockTool = MockTool(callName: "cat", name: "cat", result: .success("meow"))
        await toolManager?.updateAvailableTools([mockTool.toAnyTool()])

        let arguments: [String: AnyCodable] = ["workspaceID": AnyCodable("not-a-uuid")]

        do {
            _ = try await toolRouter.execute(
                tool: .known("cat"),
                arguments: arguments,
                threadID: session.id
            )
            Issue.record("Expected invalidWorkspaceID to be thrown")
        } catch let ToolError.invalidWorkspaceID(value) {
            #expect(value == "not-a-uuid")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Empty-string workspaceID fails closed with invalidWorkspaceID (PKRR-015)")
    func emptyWorkspaceIDFailsClosed() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("cat"))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        let mockTool = MockTool(callName: "cat", name: "cat", result: .success("meow"))
        await toolManager?.updateAvailableTools([mockTool.toAnyTool()])

        let arguments: [String: AnyCodable] = ["workspaceID": AnyCodable("")]

        do {
            _ = try await toolRouter.execute(
                tool: .known("cat"),
                arguments: arguments,
                threadID: session.id
            )
            Issue.record("Expected invalidWorkspaceID to be thrown")
        } catch ToolError.invalidWorkspaceID {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Non-string workspaceID (number) fails closed with invalidWorkspaceID (PKRR-015)")
    func nonStringWorkspaceIDFailsClosed() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("cat"))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        let mockTool = MockTool(callName: "cat", name: "cat", result: .success("meow"))
        await toolManager?.updateAvailableTools([mockTool.toAnyTool()])

        let arguments: [String: AnyCodable] = ["workspaceID": AnyCodable(123)]

        do {
            _ = try await toolRouter.execute(
                tool: .known("cat"),
                arguments: arguments,
                threadID: session.id
            )
            Issue.record("Expected invalidWorkspaceID to be thrown")
        } catch ToolError.invalidWorkspaceID {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Workspace lookup searches primary then attached in order")
    func workspaceLookupOrderPrimaryFirst() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        let session = try await threadManager.createThread()

        // Attach an additional workspace (attached location) alongside the primary runtime workspace.
        let attachedWorkspaceId = UUID()
        let attachedWorkspaceRef = try WorkspaceReference(
            id: attachedWorkspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://remote")),
            location: .attached,
            originID: UUID()
        )
        try await mockPersistence.saveWorkspace(attachedWorkspaceRef)
        try await threadManager.attachWorkspace(attachedWorkspaceId, to: session.id)

        // Register the tool in BOTH the primary workspace and the attached workspace.
        // The primary workspace is the runtime workspace created by `createThread`.
        let workspaces = try await threadManager.getWorkspaces(for: session.id)
        let primaryId = try #require(workspaces.primary?.id)
        let toolId = "shared_tool"
        try await mockPersistence.addToolToWorkspace(workspaceId: primaryId, tool: .known(toolId))
        try await mockPersistence.addToolToWorkspace(workspaceId: attachedWorkspaceId, tool: .known(toolId))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        let mockTool = MockTool(callName: toolId, name: toolId, result: .success("primary success"))
        await toolManager?.updateAvailableTools([mockTool.toAnyTool()])

        let result = try await toolRouter.execute(
            tool: .known(toolId),
            arguments: [:],
            threadID: session.id
        )

        // Primary (runtime) workspace should win → local execution → .completed.
        guard case .completed = result else {
            Issue.record("Expected .completed (primary/runtime should win), got \(result)")
            return
        }
    }

    @Test("Explicit valid workspaceID overrides default lookup")
    func explicitValidWorkspaceIDOverridesDefault() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        let session = try await threadManager.createThread()

        // Attach an additional workspace (attached location).
        let attachedWorkspaceId = UUID()
        let attachedWorkspaceRef = try WorkspaceReference(
            id: attachedWorkspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://remote")),
            location: .attached,
            originID: UUID()
        )
        try await mockPersistence.saveWorkspace(attachedWorkspaceRef)
        try await threadManager.attachWorkspace(attachedWorkspaceId, to: session.id)

        // Register the tool in the primary workspace only — default lookup would find it there.
        let workspaces = try await threadManager.getWorkspaces(for: session.id)
        let primaryId = try #require(workspaces.primary?.id)
        let toolId = "tool_a"
        try await mockPersistence.addToolToWorkspace(workspaceId: primaryId, tool: .known(toolId))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        let mockTool = MockTool(callName: toolId, name: toolId, result: .success("ok"))
        await toolManager?.updateAvailableTools([mockTool.toAnyTool()])

        // Explicitly request the attached workspace — should override the default primary lookup.
        let arguments: [String: AnyCodable] = ["workspaceID": AnyCodable(attachedWorkspaceId.uuidString)]

        let result = try await toolRouter.execute(
            tool: .known(toolId),
            arguments: arguments,
            threadID: session.id
        )

        // Explicit workspaceID points to the attached workspace → defer externally.
        guard case .deferredExternally = result else {
            Issue.record("Expected .deferredExternally (explicit attached workspace), got \(result)")
            return
        }
    }

    @Test("No workspaces at all resolves to toolNotFound")
    func noWorkspacesAtAllResolvesToToolNotFound() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        let session = try await threadManager.createThread()
        // Detach all workspaces to simulate "no workspaces at all."
        for attachedId in session.attachedWorkspaceIDs {
            try await threadManager.detachWorkspace(attachedId, from: session.id)
        }
        let workspaces = try await threadManager.getWorkspaces(for: session.id)
        #expect(workspaces.primary == nil)
        #expect(workspaces.attached.isEmpty == true)

        do {
            _ = try await toolRouter.execute(
                tool: .known("any_tool"),
                arguments: [:],
                threadID: session.id
            )
            Issue.record("Expected toolNotFound")
        } catch ToolError.toolNotFound {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - MockTool (shared with ToolRouterTests)

    struct MockTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName: String
        let name: String
        let description = "A mock tool for testing"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        var result: ToolResult

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            if !result.success, result.error == "client_tools_disallowed_on_private_thread" {
                throw ToolError.attachedToolsDisallowedOnPrivateThread
            }
            return result
        }
    }

    /// A tool that throws a specific `ToolError` so remediation guidance can be asserted.
    struct FailingTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName: String
        let name: String
        let description = "A tool that always fails"
        let requiresPermission = false
        let thrownError: any Error
        let parametersSchema = makeEmptyObjectSchema()

        init(id: String, error: any Error) {
            self.callName = id
            name = id
            thrownError = error
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            throw thrownError
        }
    }
}

// MARK: - Recasted tool-turn projection tests (formerly ToolTurnProjector isolation tests)

struct ToolTurnProjectionTests {
    private func setupThreadManager() async throws -> (ThreadManager, MockPersistenceService) {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceRoot: workspace.root
        )
        return (threadManager, mockPersistence)
    }

    private struct MockTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName: String
        let name: String
        let description = "A mock tool for testing"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        var result: ToolResult

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            result
        }
    }

    private struct FailingTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName: String
        let name: String
        let description = "A tool that always fails"
        let requiresPermission = false
        let thrownError: any Error
        let parametersSchema = makeEmptyObjectSchema()

        init(id: String, error: any Error) {
            self.callName = id
            name = id
            thrownError = error
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            throw thrownError
        }
    }

    @Test("Completed outcomes persist tool messages and emit success events")
    func completedOutcomeProjection() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("tool"))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        await toolManager?.updateAvailableTools([MockTool(callName: "tool", name: "tool", result: .success("done")).toAnyTool()])

        let call = ParsedToolCall(callId: "call-1", name: "tool", argumentsJSON: "{}")

        let events = try await captureProjectedToolEvents { continuation in
            let result = try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call],
                availableTools: [],
                continuation: continuation
            )

            #expect(result.hasDeferred == false)
            #expect(result.hasPersistenceFailure == false)
            #expect(result.resolvedToolParams.count == 1)
            #expect(result.resolvedToolParams.first?.content == "done")
        }

        #expect(mockPersistence.messages.count == 1)
        #expect(mockPersistence.messages.first?.content == "done")
        #expect(events.contains(where: {
            if case let .completion(event) = $0,
               case let .toolExecution(toolCallId, status) = event,
               case let .success(result) = status
            {
                return toolCallId == "call-1" && result.output == "done"
            }
            return false
        }))
    }

    @Test("Error projection persists error output and emits failed events")
    func errorProjection() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("tool"))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        await toolManager?.updateAvailableTools([FailingTool(id: "tool", error: ToolError.executionFailed("boom")).toAnyTool()])

        let call = ParsedToolCall(callId: "call-2", name: "tool", argumentsJSON: "{}")

        let events = try await captureProjectedToolEvents { continuation in
            let result = try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call],
                availableTools: [],
                continuation: continuation
            )

            #expect(result.hasDeferred == false)
            #expect(result.hasPersistenceFailure == false)
            #expect(result.resolvedToolParams.count == 1)
            #expect(result.resolvedToolParams.first?.content.contains("Error:") == true)
        }

        #expect(mockPersistence.messages.count == 1)
        #expect(mockPersistence.messages.first?.content.contains("Error:") == true)
        #expect(events.contains(where: {
            if case let .completion(event) = $0,
               case let .toolExecution(toolCallId, status) = event,
               case .failed = status
            {
                return toolCallId == "call-2"
            }
            return false
        }))
    }

    @Test("Error projection appends the error's remediation as model-facing recovery guidance")
    func errorProjectionSurfacesRemediation() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, messageStore: mockPersistence)

        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("cat"))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        let error = ToolError.invalidArgument("count", expected: "Int", got: "4.7")
        await toolManager?.updateAvailableTools([FailingTool(id: "cat", error: error).toAnyTool()])

        let call = ParsedToolCall(callId: "call-3", name: "cat", argumentsJSON: "{}")

        _ = try await captureProjectedToolEvents { continuation in
            let result = try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call],
                availableTools: [],
                continuation: continuation
            )

            let message = try #require(result.resolvedToolParams.first)
            #expect(message.content.contains("Error:"))
            #expect(message.content.contains("How to fix:"))
            #expect(message.content.contains(error.remediation ?? "<none>"))
        }

        #expect(mockPersistence.messages.first?.content.contains("How to fix:") == true)
    }
}

// MARK: - Tool durability ordering tests (PKRR-016)

struct ToolDurabilityOrderingTests {
    private func setupThreadManager() async throws -> (ThreadManager, MockPersistenceService) {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceRoot: workspace.root
        )
        return (threadManager, mockPersistence)
    }

    private struct MockTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName: String
        let name: String
        let description = "A mock tool for testing"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        var result: ToolResult

        func canExecute() async -> Bool { true }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            result
        }
    }

    private struct FailingTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName: String
        let name: String
        let description = "A tool that always fails"
        let requiresPermission = false
        let thrownError: any Error
        let parametersSchema = makeEmptyObjectSchema()

        init(id: String, error: any Error) {
            callName = id
            name = id
            thrownError = error
        }

        func canExecute() async -> Bool { true }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            throw thrownError
        }
    }

    /// Sets up a thread with a single registered tool and returns the router (backed by a
    /// `FailingMessageStore`) plus the thread ID and the store for assertions.
    private func setupRouterWithFailingStore(
        tool: any PKContracts.Tool
    ) async throws -> (ToolRouter, FailingMessageStore, UUID) {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let failingStore = FailingMessageStore()
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            messageStore: failingStore
        )

        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(tool.callName))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        await toolManager?.updateAvailableTools([tool.toAnyTool()])

        return (toolRouter, failingStore, session.id)
    }

    @Test("A successful tool with a failing store never emits terminal success (PKRR-016)")
    func successfulToolFailingStoreDoesNotEmitSuccess() async throws {
        let tool = MockTool(callName: "tool", name: "tool", result: .success("done"))
        let (router, failingStore, threadID) = try await setupRouterWithFailingStore(tool: tool)

        let call = ParsedToolCall(callId: "call-1", name: "tool", argumentsJSON: "{}")

        let events = try await captureProjectedToolEvents { continuation in
            let result = try await router.handlePendingToolCalls(
                threadId: threadID,
                calls: [call],
                availableTools: [],
                continuation: continuation
            )

            #expect(result.hasDeferred == false)
            #expect(result.hasPersistenceFailure)
            #expect(result.resolvedToolParams.isEmpty)
        }

        // Persistence was attempted (the store received the message before throwing).
        #expect(failingStore.attemptedMessages.count == 1)
        #expect(failingStore.attemptedMessages.first?.content == "done")
        #expect(failingStore.attemptedMessages.first?.toolCallID == "call-1")

        // The stream must NOT contain a terminal .success event — persistence failed, so
        // success was never emitted.
        #expect(!events.contains(where: {
            if case let .completion(.toolExecution(toolCallId, status)) = $0,
               case .success = status
            {
                return toolCallId == "call-1"
            }
            return false
        }))

        // The stream MUST contain a .persistenceFailed terminal event.
        #expect(events.contains(where: {
            if case let .completion(.toolExecution(toolCallId, status)) = $0,
               case .persistenceFailed = status
            {
                return toolCallId == "call-1"
            }
            return false
        }))
    }

    @Test("A failed tool with a failing store never emits terminal failure (PKRR-016)")
    func failedToolFailingStoreDoesNotEmitFailed() async throws {
        let tool = FailingTool(id: "tool", error: ToolError.executionFailed("boom"))
        let (router, failingStore, threadID) = try await setupRouterWithFailingStore(tool: tool)

        let call = ParsedToolCall(callId: "call-2", name: "tool", argumentsJSON: "{}")

        let events = try await captureProjectedToolEvents { continuation in
            let result = try await router.handlePendingToolCalls(
                threadId: threadID,
                calls: [call],
                availableTools: [],
                continuation: continuation
            )

            #expect(result.hasDeferred == false)
            #expect(result.hasPersistenceFailure)
            #expect(result.resolvedToolParams.isEmpty)
        }

        // Persistence was attempted.
        #expect(failingStore.attemptedMessages.count == 1)
        #expect(failingStore.attemptedMessages.first?.content.contains("Error:") == true)
        #expect(failingStore.attemptedMessages.first?.toolCallID == "call-2")

        // The stream must NOT contain a terminal .failed event.
        #expect(!events.contains(where: {
            if case let .completion(.toolExecution(toolCallId, status)) = $0,
               case .failed = status
            {
                return toolCallId == "call-2"
            }
            return false
        }))

        // The stream MUST contain a .persistenceFailed terminal event.
        #expect(events.contains(where: {
            if case let .completion(.toolExecution(toolCallId, status)) = $0,
               case .persistenceFailed = status
            {
                return toolCallId == "call-2"
            }
            return false
        }))
    }

    @Test("A successful tool with a working store emits terminal success and no persistenceFailed (PKRR-016)")
    func successfulToolWorkingStoreEmitsSuccess() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            messageStore: mockPersistence
        )

        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("tool"))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        await toolManager?.updateAvailableTools([
            MockTool(callName: "tool", name: "tool", result: .success("done")).toAnyTool()
        ])

        let call = ParsedToolCall(callId: "call-3", name: "tool", argumentsJSON: "{}")

        let events = try await captureProjectedToolEvents { continuation in
            _ = try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call],
                availableTools: [],
                continuation: continuation
            )
        }

        // The message was persisted.
        #expect(mockPersistence.messages.count == 1)
        #expect(mockPersistence.messages.first?.content == "done")

        // The stream contains a terminal .success event.
        #expect(events.contains(where: {
            if case let .completion(.toolExecution(toolCallId, status)) = $0,
               case .success = status
            {
                return toolCallId == "call-3"
            }
            return false
        }))

        // The stream does NOT contain a .persistenceFailed event.
        #expect(!events.contains(where: {
            if case let .completion(.toolExecution(_, status)) = $0,
               case .persistenceFailed = status
            {
                return true
            }
            return false
        }))
    }

    @Test("Batch with one succeeding and one failing store: first emits success, second emits persistenceFailed (PKRR-016)")
    func batchMixedPersistenceResults() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let batchStore = BatchFailingMessageStore()
        batchStore.failAfterSaveCount = 1
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            messageStore: batchStore
        )

        let session = try await threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await threadManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("tool"))

        let toolManager = await threadManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        await toolManager?.updateAvailableTools([
            MockTool(callName: "tool", name: "tool", result: .success("ok")).toAnyTool()
        ])

        let call1 = ParsedToolCall(callId: "call-a", name: "tool", argumentsJSON: "{}")
        let call2 = ParsedToolCall(callId: "call-b", name: "tool", argumentsJSON: "{}")

        let events = try await captureProjectedToolEvents { continuation in
            let result = try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call1, call2],
                availableTools: [],
                continuation: continuation
            )
            #expect(result.hasPersistenceFailure)
            #expect(result.resolvedToolParams.count == 1)
        }

        // First save succeeds, second fails.
        #expect(batchStore.saveCallCount == 2)
        #expect(batchStore.messages.count == 1)

        // First tool call: terminal .success.
        #expect(events.contains(where: {
            if case let .completion(.toolExecution(toolCallId, status)) = $0,
               case .success = status
            {
                return toolCallId == "call-a"
            }
            return false
        }))

        // Second tool call: terminal .persistenceFailed (not .success).
        #expect(events.contains(where: {
            if case let .completion(.toolExecution(toolCallId, status)) = $0,
               case .persistenceFailed = status
            {
                return toolCallId == "call-b"
            }
            return false
        }))
        #expect(!events.contains(where: {
            if case let .completion(.toolExecution(toolCallId, status)) = $0,
               case .success = status
            {
                return toolCallId == "call-b"
            }
            return false
        }))
    }
}

// MARK: - ParsedToolCall decode contract tests

struct ParsedToolCallTests {
    @Test("Valid JSON object decodes to non-nil arguments")
    func validJSONDecodes() {
        let call = ParsedToolCall(callId: "1", name: "test", argumentsJSON: "{\"key\": \"value\"}")
        #expect(call.arguments != nil)
        #expect(call.arguments?["key"]?.value as? String == "value")
    }

    @Test("Invalid JSON produces nil arguments, not empty dictionary")
    func invalidJSONProducesNil() {
        let call = ParsedToolCall(callId: "2", name: "test", argumentsJSON: "not json at all")
        #expect(call.arguments == nil)
    }

    @Test("Non-object JSON (array) produces nil arguments")
    func arrayJSONProducesNil() {
        let call = ParsedToolCall(callId: "3", name: "test", argumentsJSON: "[1,2,3]")
        #expect(call.arguments == nil)
    }

    @Test("Empty string produces nil arguments")
    func emptyStringProducesNil() {
        let call = ParsedToolCall(callId: "4", name: "test", argumentsJSON: "")
        #expect(call.arguments == nil)
    }

    @Test("Empty JSON object decodes to empty dictionary")
    func emptyObjectDecodes() {
        let call = ParsedToolCall(callId: "5", name: "test", argumentsJSON: "{}")
        #expect(call.arguments != nil)
        #expect(call.arguments?.isEmpty == true)
    }
}

// MARK: - ToolError v1 model contract tests

struct ToolErrorModelTests {
    @Test("All v1 error categories have distinct error codes")
    func distinctErrorCodes() {
        let codes: Set<Int> = [
            ToolError.missingArgument("x").errorCode,
            ToolError.invalidArgument("x", expected: "Int", got: "String").errorCode,
            ToolError.malformedArguments("bad").errorCode,
            ToolError.schemaMismatch("bad").errorCode,
            ToolError.executionFailed("fail").errorCode,
            ToolError.timedOutButMayStillBeRunning(timeout: 30).errorCode,
            ToolError.toolNotFound("t").errorCode,
            ToolError.workspaceNotFound(UUID()).errorCode,
            ToolError.requestOriginUnavailable.errorCode,
            ToolError.attachedToolsDisallowedOnPrivateThread.errorCode,
            ToolError.permissionDenied("t").errorCode,
            ToolError.unmatchedToolOutput("call_1").errorCode,
            ToolError.invalidWorkspaceID("bad").errorCode,
        ]
        #expect(codes.count == 13)
    }

    @Test("All v1 error categories have non-empty user-friendly messages")
    func nonEmptyUserFriendlyMessages() {
        let errors: [ToolError] = [
            .missingArgument("param"),
            .invalidArgument("param", expected: "Int", got: "String"),
            .malformedArguments("not JSON"),
            .schemaMismatch("missing required field"),
            .executionFailed("timeout"),
            .timedOutButMayStillBeRunning(timeout: 30),
            .toolNotFound("unknown"),
            .workspaceNotFound(UUID()),
            .requestOriginUnavailable,
            .attachedToolsDisallowedOnPrivateThread,
            .permissionDenied("tool"),
            .unmatchedToolOutput("call_1"),
            .invalidWorkspaceID("not-a-uuid"),
        ]
        for err in errors {
            #expect(!err.userFriendlyMessage.isEmpty, "Empty message for \(err)")
        }
    }

    @Test("All v1 error categories have remediation guidance")
    func allHaveRemediation() {
        let errors: [ToolError] = [
            .missingArgument("param"),
            .invalidArgument("param", expected: "Int", got: "String"),
            .malformedArguments("not JSON"),
            .schemaMismatch("missing required field"),
            .executionFailed("timeout"),
            .timedOutButMayStillBeRunning(timeout: 30),
            .toolNotFound("unknown"),
            .workspaceNotFound(UUID()),
            .requestOriginUnavailable,
            .attachedToolsDisallowedOnPrivateThread,
            .permissionDenied("tool"),
            .unmatchedToolOutput("call_1"),
            .invalidWorkspaceID("not-a-uuid"),
        ]
        for err in errors {
            #expect(err.remediation != nil, "Missing remediation for \(err)")
        }
    }
}

// MARK: - ToolParameters decode pattern tests

struct ToolParametersTests {
    @Test("require throws missingArgument when key absent")
    func requireMissing() {
        let params = ToolParameters([:])
        do {
            _ = try params.require("missing", as: String.self)
            Issue.record("Should have thrown missingArgument")
        } catch ToolError.missingArgument("missing") {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("require returns value when present and correct type")
    func requirePresent() throws {
        let params = ToolParameters(["name": "test"])
        let name = try params.require("name", as: String.self)
        #expect(name == "test")
    }

    @Test("require coerces Double to Int")
    func requireIntCoercion() throws {
        let params = ToolParameters(["count": 3.0])
        let count = try params.require("count", as: Int.self)
        #expect(count == 3)
    }

    @Test("require throws invalidArgument on type mismatch")
    func requireTypeMismatch() {
        let params = ToolParameters(["value": "string"])
        do {
            _ = try params.require("value", as: Int.self)
            Issue.record("Should have thrown invalidArgument")
        } catch let ToolError.invalidArgument(key, expected, got) {
            #expect(key == "value")
            #expect(expected == "Int")
            #expect(got == "String")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("optional returns nil when key absent")
    func optionalMissing() {
        let params = ToolParameters([:])
        let value = params.optional("missing", as: String.self)
        #expect(value == nil)
    }

    @Test("optional returns value when present")
    func optionalPresent() {
        let params = ToolParameters(["limit": 10])
        let limit = params.optional("limit", as: Int.self)
        #expect(limit == 10)
    }
}
