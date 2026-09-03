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
            runtimeRepository: runtimeRepository ?? mockPersistence,
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
                threadID: threadID,
                availableTools: [tool.toAnyTool()]
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
            threadID: threadID,
            availableTools: [tool.toAnyTool()]
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
                availableTools: [tool.toAnyTool()],
                continuation: continuation
            )
        }

        #expect(tool.didExecute == false)
        #expect(result.hasDeferred == false)
        #expect(result.resolvedToolParams.first?.content.contains("permission") == true)
    }

    @Test("Workspace call_tool ambiguity returns a rich correction without execution")
    func workspaceCallToolAmbiguity() async throws {
        let tool = MockTool(callName: "read_file", name: "read_file", result: .success("workspace output"))
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
            .init(workspace: first, label: first.uri.description, isPrimary: true, tools: [tool.toAnyTool()]),
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
        let tool = MockTool(callName: "read_file", name: "read_file", result: .success("workspace output"))
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
            .init(workspace: workspace, label: workspace.uri.description, isPrimary: true, tools: [tool.toAnyTool()]),
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

    @Test("Primary Workspace tool activity remains on the executing Thread")
    func primaryWorkspaceActivityStaysOnExecutingThread() async throws {
        let tool = MockTool(callName: "read_file", name: "read_file", result: .success("workspace output"))
        let runtimeRepository = InMemoryThreadRuntimeRepository()
        let (router, threadID, persistence) = try await setupRouter(
            with: tool,
            approvalPolicy: DenyAllToolApprovalPolicy(),
            runtimeRepository: runtimeRepository
        )
        try await runtimeRepository.saveThread(Thread(id: threadID))
        let privateThreadID = UUID()
        try await runtimeRepository.saveThread(Thread(id: privateThreadID, isPrivate: true))
        let admission = try await runtimeRepository.admitTurn(
            threadID: threadID,
            requestID: UUID(),
            callerIntentFingerprint: "primary-history-boundary"
        )
        let workspace = try #require(persistence.workspaces.first)
        let catalog = WorkspaceToolCatalog(entries: [
            .init(workspace: workspace, label: workspace.uri.description, isPrimary: true, tools: [tool.toAnyTool()]),
        ])
        let call = ParsedToolCall(
            callId: "call-primary-history-boundary",
            name: "call_tool",
            argumentsJSON: "{\"tool\":\"read_file\",\"at\":\"\(workspace.id.uuidString)\",\"arguments\":{}}"
        )

        _ = try await captureProjectedToolEventsResult { continuation in
            try await router.handlePendingToolCalls(
                threadId: threadID,
                turnID: admission.turn.identity.turnID,
                calls: [call],
                availableTools: [catalog.callTool],
                workspaceToolCatalog: catalog,
                continuation: continuation
            )
        }

        let sourceMessages = try await runtimeRepository.fetchMessages(for: threadID)
        #expect(sourceMessages.count == 1)
        #expect(sourceMessages.first?.threadID == threadID)
        #expect(try await runtimeRepository.fetchMessages(for: privateThreadID).isEmpty)
    }

    @Test("Workspace call_tool failures retain route provenance in events and records")
    func workspaceCallToolFailureProvenance() async throws {
        let tool = MockTool(callName: "read_file", name: "read_file", result: .failure("workspace failed"))
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
            .init(workspace: workspace, label: workspace.uri.description, isPrimary: true, tools: [tool.toAnyTool()]),
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

    @Test("Workspace call_tool rejects a released Thread binding")
    func workspaceCallToolReleasedBindingFailsClosed() async throws {
        let (threadManager, persistence) = try await setupThreadManager()
        let runtimeRepository = InMemoryThreadRuntimeRepository()
        let router = ToolRouter(
            threadManager: threadManager,
            runtimeRepository: runtimeRepository
        )
        let thread = try await threadManager.createThread()
        let tool = MockTool(callName: "read_file", name: "read_file", result: .success("workspace output"))
        let workspace = try WorkspaceReference(
            id: UUID(),
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await persistence.saveWorkspace(workspace)
        try await threadManager.attachWorkspace(workspace.id, to: thread.id)
        try await persistence.addToolToWorkspace(workspaceId: workspace.id, tool: .known(tool.callName))
        let toolManager = try #require(await threadManager.getToolManager(for: thread.id))
        await toolManager.updateAvailableTools([tool.toAnyTool()])

        try await runtimeRepository.saveThread(thread)
        let admission = try await runtimeRepository.admitTurn(
            threadID: thread.id,
            requestID: UUID(),
            callerIntentFingerprint: "released-binding"
        )
        let catalog = WorkspaceToolCatalog(entries: [
            .init(
                workspace: workspace,
                label: workspace.uri.description,
                isPrimary: false,
                tools: [tool.toAnyTool()]
            ),
        ])

        // Keep the admission snapshot but remove its durable authority before the side effect.
        try await threadManager.detachWorkspace(workspace.id, from: thread.id)

        let call = ParsedToolCall(
            callId: "call-released",
            name: "call_tool",
            argumentsJSON: "{\"tool\":\"read_file\",\"at\":\"\(workspace.id.uuidString)\",\"arguments\":{}}"
        )
        let result = try await captureProjectedToolEventsResult { continuation in
            try await router.handlePendingToolCalls(
                threadId: thread.id,
                turnID: admission.turn.identity.turnID,
                calls: [call],
                availableTools: [catalog.callTool],
                workspaceToolCatalog: catalog,
                continuation: continuation
            )
        }

        #expect(result.hasDeferred == false)
        #expect(result.resolvedToolParams.count == 1)
        let results = try await runtimeRepository.fetchToolResults(turnID: admission.turn.identity.turnID)
        #expect(results.first?.succeeded == false)
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
                availableTools: [tool.toAnyTool()],
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
            threadID: threadID,
            availableTools: [tool.toAnyTool()]
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
                runtimeRepository: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
        )
        return (threadManager, mockPersistence)
    }

    @Test

    func executeLocally() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, runtimeRepository: mockPersistence)

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

        let result = try await toolRouter.execute(
            tool: toolRef,
            arguments: arguments,
            threadID: session.id,
            availableTools: [mockTool.toAnyTool()]
        )
        guard case let .completed(output) = result else {
            Issue.record("Expected .completed outcome")
            return
        }
        #expect(output == "Local success")
    }

    @Test("A dynamic per-turn tool (passed via availableTools) executes locally even when the thread has no attached workspace at all (YAK-19)")
    func dynamicToolExecutesWithoutAnyWorkspace() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(threadManager: threadManager, runtimeRepository: mockPersistence)

        // A freshly created thread still gets its own runtime workspace from `createThread`,
        // so to reproduce "no workspace at all" we must detach it — mirroring a thread that
        // never had a folder attached and exercises only workspace-independent demo tools like
        // `calculator`/`current_datetime`.
        let session = try await threadManager.createThread()
        let initialWorkspaces = try await threadManager.getWorkspaces(for: session.id)
        for workspaceID in ([initialWorkspaces.primary?.id] + initialWorkspaces.attached.map(\.id)).compactMap(\.self) {
            try await threadManager.detachWorkspace(workspaceID, from: session.id)
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
        let toolRouter = ToolRouter(threadManager: threadManager, runtimeRepository: mockPersistence)

        let session = try await threadManager.createThread()
        let toolRef = ToolReference.known("unknown")
        let arguments: [String: AnyCodable] = [:]

        do {
            _ = try await toolRouter.execute(
                tool: toolRef,
                arguments: arguments,
                threadID: session.id,
                availableTools: []
            )
            Issue.record("Should have thrown toolNotFound")
        } catch ToolError.toolNotFound {
            // Expected
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }
    }

    @Test("Local tool execution timeout is projected as a tool error")
    func localToolExecutionTimeoutIsProjectedAsToolError() async throws {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            runtimeRepository: mockPersistence,
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
        let neverFinishingTool = NeverFinishingTool().toAnyTool()
        await toolManager?.updateAvailableTools([neverFinishingTool])

        let call = ParsedToolCall(callId: "call-timeout", name: "never_finishes", argumentsJSON: "{}")
        let events = try await captureProjectedToolEvents { continuation in
            let result = try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call],
                availableTools: [neverFinishingTool],
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
            runtimeRepository: mockPersistence,
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
        let uncooperativeTool = UncooperativeTool(started: started, release: release).toAnyTool()
        await toolManager?.updateAvailableTools([uncooperativeTool])

        let call = ParsedToolCall(callId: "call-timeout", name: "uncooperative", argumentsJSON: "{}")

        let result = try await captureProjectedToolEventsResult { continuation in
            try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call],
                availableTools: [uncooperativeTool],
                continuation: continuation
            )
        }
        #expect(result.hasDeferred == false)
        #expect(result.resolvedToolParams.first?.content.contains("timed out") == true)
    }
}

// MARK: - Workspace dispatcher interface tests

@Suite("Workspace tool dispatcher")
struct WorkspaceToolDispatcherTests {
    private struct MockTool: PKContracts.Tool {
        let callName: String
        var name: String { callName }
        let description = "A mock Workspace tool"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool { true }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            .success("done")
        }
    }

    private func makeDispatcher() -> WorkspaceToolDispatcher {
        let persistence = MockPersistenceService()
        let manager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                runtimeRepository: persistence,
                toolPersistence: persistence
            ),
            workspaceProfile: .noWorkspace,
            workspaceCreator: MockWorkspaceCreator()
        )
        return WorkspaceToolDispatcher(threadManager: manager)
    }

    private func workspace(
        path: String,
        location: WorkspaceReference.WorkspaceLocation = .runtime
    ) -> WorkspaceReference {
        WorkspaceReference(
            uri: WorkspaceURI(host: "dispatcher-tests", path: path),
            location: location,
            tools: [.known("cat")],
            rootPath: "/tmp"
        )
    }

    private func catalog(_ workspaces: [WorkspaceReference]) -> WorkspaceToolCatalog {
        let tool = MockTool(callName: "cat").toAnyTool()
        return WorkspaceToolCatalog(entries: workspaces.map {
            .init(
                workspace: $0,
                label: $0.uri.description,
                isPrimary: false,
                tools: [tool]
            )
        })
    }

    @Test("Unique captured match prepares an implicit route")
    func uniqueMatchIsImplicit() throws {
        let workspace = workspace(path: "/unique")
        let dispatch = try makeDispatcher().prepare(
            call: ParsedToolCall(
                callId: "call-unique",
                name: WorkspaceToolDispatcher.callName,
                argumentsJSON: #"{"tool":"cat","arguments":{}}"#
            ),
            catalog: catalog([workspace])
        )

        #expect(dispatch.route.workspaceID == workspace.id)
        #expect(dispatch.route.routing == .implicit)
        #expect(dispatch.route.tool.callName == "cat")
    }

    @Test("Duplicate captured matches fail with candidate provenance")
    func duplicateMatchesAreAmbiguous() throws {
        let first = workspace(path: "/first")
        let second = workspace(path: "/second")

        do {
            _ = try makeDispatcher().prepare(
                call: ParsedToolCall(
                    callId: "call-ambiguous",
                    name: WorkspaceToolDispatcher.callName,
                    argumentsJSON: #"{"tool":"cat"}"#
                ),
                catalog: catalog([first, second])
            )
            Issue.record("Expected ambiguousWorkspaceTool")
        } catch let ToolError.ambiguousWorkspaceTool(tool, candidates) {
            #expect(tool == "cat")
            #expect(Set(candidates.map(\.workspaceID)) == Set([first.id, second.id]))
        }
    }

    @Test("Explicit at selects one captured Workspace")
    func explicitAtSelectsWorkspace() throws {
        let first = workspace(path: "/first")
        let second = workspace(path: "/second")
        let arguments = #"{"tool":"cat","at":"\#(second.id.uuidString)"}"#

        let dispatch = try makeDispatcher().prepare(
            call: ParsedToolCall(
                callId: "call-explicit",
                name: WorkspaceToolDispatcher.callName,
                argumentsJSON: arguments
            ),
            catalog: catalog([first, second])
        )

        #expect(dispatch.route.workspaceID == second.id)
        #expect(dispatch.route.routing == .explicit)
    }

    @Test("Malformed explicit at fails closed")
    func malformedAtFailsClosed() throws {
        do {
            _ = try makeDispatcher().prepare(
                call: ParsedToolCall(
                    callId: "call-malformed",
                    name: WorkspaceToolDispatcher.callName,
                    argumentsJSON: #"{"tool":"cat","at":"not-a-uuid"}"#
                ),
                catalog: catalog([workspace(path: "/only")])
            )
            Issue.record("Expected invalidWorkspaceID")
        } catch let ToolError.invalidWorkspaceID(value) {
            #expect(value == "not-a-uuid")
        }
    }

    @Test("Empty admission catalog exposes no Workspace route")
    func emptyCatalogHasNoRoute() throws {
        do {
            _ = try makeDispatcher().prepare(
                call: ParsedToolCall(
                    callId: "call-empty",
                    name: WorkspaceToolDispatcher.callName,
                    argumentsJSON: #"{"tool":"cat"}"#
                ),
                catalog: WorkspaceToolCatalog(entries: [])
            )
            Issue.record("Expected toolNotFound")
        } catch ToolError.toolNotFound(WorkspaceToolDispatcher.callName) {
            // expected
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
                runtimeRepository: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
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
        let toolRouter = ToolRouter(threadManager: threadManager, runtimeRepository: mockPersistence)

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
        let tool = MockTool(callName: "tool", name: "tool", result: .success("done")).toAnyTool()
        await toolManager?.updateAvailableTools([tool])

        let call = ParsedToolCall(callId: "call-1", name: "tool", argumentsJSON: "{}")

        let events = try await captureProjectedToolEvents { continuation in
            let result = try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call],
                availableTools: [tool],
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
        let toolRouter = ToolRouter(threadManager: threadManager, runtimeRepository: mockPersistence)

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
        let tool = FailingTool(id: "tool", error: ToolError.executionFailed("boom")).toAnyTool()
        await toolManager?.updateAvailableTools([tool])

        let call = ParsedToolCall(callId: "call-2", name: "tool", argumentsJSON: "{}")

        let events = try await captureProjectedToolEvents { continuation in
            let result = try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call],
                availableTools: [tool],
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
        let toolRouter = ToolRouter(threadManager: threadManager, runtimeRepository: mockPersistence)

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
        let tool = FailingTool(id: "cat", error: error).toAnyTool()
        await toolManager?.updateAvailableTools([tool])

        let call = ParsedToolCall(callId: "call-3", name: "cat", argumentsJSON: "{}")

        _ = try await captureProjectedToolEvents { continuation in
            let result = try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call],
                availableTools: [tool],
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
                runtimeRepository: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceProfile: .hostManaged(root: workspace.root)
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

    /// Sets up a thread with a single registered tool and returns the router backed by a cohesive
    /// repository configured to fail message persistence.
    private func setupRouterWithFailingStore(
        tool: any PKContracts.Tool
    ) async throws -> (ToolRouter, MockPersistenceService, UUID) {
        let (threadManager, mockPersistence) = try await setupThreadManager()
        let failingStore = MockPersistenceService()
        failingStore.saveMessageFailureAfter = 0
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            runtimeRepository: failingStore
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
                availableTools: [tool.toAnyTool()],
                continuation: continuation
            )

            #expect(result.hasDeferred == false)
            #expect(result.hasPersistenceFailure)
            #expect(result.resolvedToolParams.isEmpty)
        }

        #expect(failingStore.messages.isEmpty)

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
                availableTools: [tool.toAnyTool()],
                continuation: continuation
            )

            #expect(result.hasDeferred == false)
            #expect(result.hasPersistenceFailure)
            #expect(result.resolvedToolParams.isEmpty)
        }

        #expect(failingStore.messages.isEmpty)

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
            runtimeRepository: mockPersistence
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
        let tool = MockTool(callName: "tool", name: "tool", result: .success("done")).toAnyTool()
        await toolManager?.updateAvailableTools([tool])

        let call = ParsedToolCall(callId: "call-3", name: "tool", argumentsJSON: "{}")

        let events = try await captureProjectedToolEvents { continuation in
            _ = try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call],
                availableTools: [tool],
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
        let batchStore = MockPersistenceService()
        batchStore.saveMessageFailureAfter = 1
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            runtimeRepository: batchStore
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
        let tool = MockTool(callName: "tool", name: "tool", result: .success("ok")).toAnyTool()
        await toolManager?.updateAvailableTools([tool])

        let call1 = ParsedToolCall(callId: "call-a", name: "tool", argumentsJSON: "{}")
        let call2 = ParsedToolCall(callId: "call-b", name: "tool", argumentsJSON: "{}")

        let events = try await captureProjectedToolEvents { continuation in
            let result = try await toolRouter.handlePendingToolCalls(
                threadId: session.id,
                calls: [call1, call2],
                availableTools: [tool],
                continuation: continuation
            )
            #expect(result.hasPersistenceFailure)
            #expect(result.resolvedToolParams.count == 1)
        }

        // First save succeeds, second fails.
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
