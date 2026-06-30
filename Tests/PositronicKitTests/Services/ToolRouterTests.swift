import Foundation
import Logging
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

/// Synchronous, non-cancellable sleep used to model a blocking tool body in tests.
private func blockingThreadSleep(_ seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

private func captureProjectedToolEvents(
    _ body: @Sendable @escaping (AsyncThrowingStream<ChatEvent, Error>.Continuation) async throws -> Void
) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    let stream = AsyncThrowingStream<ChatEvent, Error> { continuation in
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
private actor ResultHolder<R: Sendable> {
    var value: R?
    func set(_ newValue: R) {
        value = newValue
    }
}

private func captureProjectedToolEventsResult<R: Sendable>(
    _ body: @Sendable @escaping (AsyncThrowingStream<ChatEvent, Error>.Continuation) async throws -> R
) async throws -> R {
    let holder = ResultHolder<R>()
    let stream = AsyncThrowingStream<ChatEvent, Error> { continuation in
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
    struct MockTool: PKShared.Tool, @unchecked Sendable {
        let id: String
        let name: String
        let description = "A mock tool for testing"
        let requiresPermission = false
        var parametersSchema: [String: AnyCodable] {
            [:]
        }

        var result: ToolResult

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: Any]) async throws -> ToolResult {
            if !result.success, result.error == "client_tools_disallowed_on_private_timeline" {
                throw ToolError.attachedToolsDisallowedOnPrivateTimeline
            }
            return result
        }
    }

    /// A permissioned tool that records whether its body ever ran, so a test can assert that an
    /// un-approved call is blocked *before* execution rather than merely failing afterwards.
    final class PermissionedTool: PKShared.Tool, @unchecked Sendable {
        let id: String
        let name: String
        let description = "A permissioned mock tool"
        let requiresPermission = true
        private(set) var didExecute = false
        var parametersSchema: [String: AnyCodable] {
            [:]
        }

        init(id: String) {
            self.id = id
            name = id
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: Any]) async throws -> ToolResult {
            didExecute = true
            return .success("executed")
        }
    }

    /// Records every gate consultation so a test can assert the gate was actually reached.
    final class RecordingGate: ToolApprovalGate, @unchecked Sendable {
        let decision: ToolApprovalDecision
        private(set) var consultedToolIds: [String] = []

        init(decision: ToolApprovalDecision) {
            self.decision = decision
        }

        func requestApproval(tool: AnyTool, arguments _: [String: AnyCodable]) async -> ToolApprovalDecision {
            consultedToolIds.append(tool.id)
            return decision
        }
    }

    /// Builds a timeline with a single registered tool and returns the router under test.
    private func setupRouter(
        with tool: any PKShared.Tool,
        approvalGate: any ToolApprovalGate
    ) async throws -> (ToolRouter, UUID) {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = ToolRouter(
            timelineManager: timelineManager,
            messageStore: mockPersistence,
            approvalGate: approvalGate
        )

        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originId: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(tool.id))

        let toolManager = await timelineManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        await toolManager?.updateAvailableTools([tool.toAnyTool()])

        return (toolRouter, session.id)
    }

    @Test("A permissioned tool is not executed when the approval gate denies it (structured call path)")
    func permissionedToolBlockedWhenDenied() async throws {
        let tool = PermissionedTool(id: "needs_permission")
        let gate = RecordingGate(decision: .deny)
        let (router, timelineId) = try await setupRouter(with: tool, approvalGate: gate)

        do {
            _ = try await router.execute(
                tool: .known("needs_permission"),
                arguments: [:],
                timelineId: timelineId
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
        let (router, timelineId) = try await setupRouter(with: tool, approvalGate: gate)

        let result = try await router.execute(
            tool: .known("needs_permission"),
            arguments: [:],
            timelineId: timelineId
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
        let (router, timelineId) = try await setupRouter(with: tool, approvalGate: gate)

        // A fallback-parsed call arrives as a ParsedToolCall through handlePendingToolCalls, the same
        // entry point the text-fallback path feeds. A denied permissioned tool must be projected as a
        // tool error and never executed.
        let call = ParsedToolCall(callId: "call-fallback", name: "needs_permission", argumentsJSON: "{}")
        let result = try await captureProjectedToolEventsResult { continuation in
            try await router.handlePendingToolCalls(
                timelineId: timelineId,
                calls: [call],
                availableTools: [],
                continuation: continuation
            )
        }

        #expect(tool.didExecute == false)
        #expect(result.hasDeferred == false)
        #expect(result.resolvedToolParams.first?.content.contains("permission") == true)
    }

    @Test("A non-permissioned tool executes without consulting the approval gate (regression)")
    func nonPermissionedToolBypassesGate() async throws {
        let tool = MockTool(id: "free_tool", name: "free_tool", result: .success("free output"))
        // A deny-all gate must not affect non-permissioned tools.
        let gate = RecordingGate(decision: .deny)
        let (router, timelineId) = try await setupRouter(with: tool, approvalGate: gate)

        let result = try await router.execute(
            tool: .known("free_tool"),
            arguments: [:],
            timelineId: timelineId
        )

        guard case let .completed(output) = result else {
            Issue.record("Expected .completed outcome, got \(result)")
            return
        }
        #expect(output == "free output")
        #expect(gate.consultedToolIds.isEmpty)
    }

    struct NeverFinishingTool: PKShared.Tool {
        let id = "never_finishes"
        let name = "never_finishes"
        let description = "A tool that never finishes unless cancelled"
        let requiresPermission = false
        var parametersSchema: [String: AnyCodable] {
            [:]
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: Any]) async throws -> ToolResult {
            try await Task.sleep(for: .seconds(60))
            return .success("late")
        }
    }

    /// A tool that blocks its executor thread and ignores cooperative cancellation entirely,
    /// modelling a synchronous/blocking tool body (e.g. a blocking subprocess or sync network call).
    struct UncooperativeTool: PKShared.Tool {
        let id = "uncooperative"
        let name = "uncooperative"
        let description = "A tool that blocks and ignores cancellation"
        let requiresPermission = false
        let blockSeconds: TimeInterval
        var parametersSchema: [String: AnyCodable] {
            [:]
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: Any]) async throws -> ToolResult {
            // A blocking, non-cancellable sleep models a synchronous tool body. It does not observe
            // Task cancellation, so the timeout must bound it without awaiting completion.
            blockingThreadSleep(blockSeconds)
            return .success("late")
        }
    }

    private func setupTimelineManager() async throws -> (TimelineManager, MockPersistenceService) {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceRoot: workspace.root
        )
        return (timelineManager, mockPersistence)
    }

    @Test

    func executeLocally() async throws {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = ToolRouter(timelineManager: timelineManager, messageStore: mockPersistence)

        // Setup session and local workspace
        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "pk://local")), location: .runtime, originId: nil)

        // Mock persistence expects WorkspaceReference
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: session.id)

        // Setup internal tools by extracting the ToolManager
        let toolManager = await timelineManager.getToolManager(for: session.id)
        try #require(toolManager != nil)

        let toolId = "local_tool"
        let mockTool = MockTool(id: toolId, name: toolId, result: .success("Local success"))
        await toolManager?.updateAvailableTools([mockTool.toAnyTool()])

        // The mock persistence doesn't automatically wire tool IDs to workspaces for `findWorkspaceForTool`
        // We simulate `addToolToWorkspace` or just rely on the tool manager falling back to the candidates.
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(toolId))

        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = ["param": AnyCodable("value")]

        let result = try await toolRouter.execute(tool: toolRef, arguments: arguments, timelineId: session.id)
        guard case let .completed(output) = result else {
            Issue.record("Expected .completed outcome")
            return
        }
        #expect(output == "Local success")
    }

    @Test

    func attachedWorkspaceToolDefersExternalExecution() async throws {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = ToolRouter(timelineManager: timelineManager, messageStore: mockPersistence)

        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()

        // Setup attached workspace
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "pk://remote")), location: .attached, originId: UUID())
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: session.id)

        let toolId = "attached_tool"
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(toolId))

        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = [:]

        do {
            let result = try await toolRouter.execute(tool: toolRef, arguments: arguments, timelineId: session.id)
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
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = ToolRouter(timelineManager: timelineManager, messageStore: mockPersistence)

        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()

        // Setup attached workspace missing an originId
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "pk://remote")), location: .attached, originId: nil)
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: session.id)

        let toolId = "attached_tool"
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(toolId))

        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = [:]

        do {
            let result = try await toolRouter.execute(tool: toolRef, arguments: arguments, timelineId: session.id)
            guard case .deferredExternally = result else {
                Issue.record("Expected .deferredExternally")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A dynamic per-turn tool (passed via availableTools) executes locally even when the timeline has no attached workspace at all (YAK-19)")
    func dynamicToolExecutesWithoutAnyWorkspace() async throws {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = ToolRouter(timelineManager: timelineManager, messageStore: mockPersistence)

        // A freshly created timeline still gets its own runtime workspace from `createTimeline`,
        // so to reproduce "no workspace at all" we must detach it — mirroring a conversation that
        // never had a folder attached and exercises only workspace-independent demo tools like
        // `calculator`/`current_datetime`.
        let session = try await timelineManager.createTimeline()
        for attachedId in session.attachedWorkspaceIds {
            try await timelineManager.detachWorkspace(attachedId, from: session.id)
        }
        let workspaces = await timelineManager.getWorkspaces(for: session.id)
        #expect(workspaces?.primary == nil)
        #expect(workspaces?.attached.isEmpty == true)

        let toolId = "dynamic_demo_tool"
        let dynamicTool = MockTool(id: toolId, name: toolId, result: .success("dynamic success"))
        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = [:]

        let result = try await toolRouter.execute(
            tool: toolRef,
            arguments: arguments,
            timelineId: session.id,
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
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = ToolRouter(timelineManager: timelineManager, messageStore: mockPersistence)

        let session = try await timelineManager.createTimeline()
        let toolRef = ToolReference.known("unknown")
        let arguments: [String: AnyCodable] = [:]

        do {
            _ = try await toolRouter.execute(tool: toolRef, arguments: arguments, timelineId: session.id)
            Issue.record("Should have thrown toolNotFound")
        } catch ToolError.toolNotFound {
            // Expected
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }
    }

    @Test("Local tool execution timeout is projected as a tool error")
    func localToolExecutionTimeoutIsProjectedAsToolError() async throws {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = ToolRouter(
            timelineManager: timelineManager,
            messageStore: mockPersistence,
            toolExecutionTimeout: 0.01
        )

        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originId: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("never_finishes"))

        let toolManager = await timelineManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        await toolManager?.updateAvailableTools([NeverFinishingTool().toAnyTool()])

        let call = ParsedToolCall(callId: "call-timeout", name: "never_finishes", argumentsJSON: "{}")
        let events = try await captureProjectedToolEvents { continuation in
            let result = try await toolRouter.handlePendingToolCalls(
                timelineId: session.id,
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

    @Test("Timeout bounds wall-clock time even for tools that ignore cancellation")
    func timeoutBoundsUncooperativeTool() async throws {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = ToolRouter(
            timelineManager: timelineManager,
            messageStore: mockPersistence,
            toolExecutionTimeout: 0.05
        )

        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originId: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: session.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("uncooperative"))

        let toolManager = await timelineManager.getToolManager(for: session.id)
        try #require(toolManager != nil)
        // Tool body blocks for 3 seconds and ignores cancellation; the 0.05s timeout must win.
        await toolManager?.updateAvailableTools([UncooperativeTool(blockSeconds: 3).toAnyTool()])

        let call = ParsedToolCall(callId: "call-timeout", name: "uncooperative", argumentsJSON: "{}")

        let start = ContinuousClock.now
        let result = try await captureProjectedToolEventsResult { continuation in
            try await toolRouter.handlePendingToolCalls(
                timelineId: session.id,
                calls: [call],
                availableTools: [],
                continuation: continuation
            )
        }
        let elapsed = ContinuousClock.now - start

        // The call must return promptly on timeout, not block until the tool finishes (~3s).
        #expect(elapsed < .seconds(1))
        #expect(result.hasDeferred == false)
        #expect(result.resolvedToolParams.first?.content.contains("timed out") == true)
    }
}

struct ToolRoutingDecisionTests {
    private struct CustomReferenceTool: PKShared.Tool, ToolReferenceProviding, @unchecked Sendable {
        let id: String
        let name: String
        let description = "custom ref tool"
        let requiresPermission = false
        let toolReference: ToolReference

        var parametersSchema: [String: AnyCodable] {
            [:]
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: Any]) async throws -> ToolResult {
            .success("ok")
        }
    }

    @Test("Dynamic available tools override fallback known-tool resolution")
    func resolvesToolReferenceFromAvailableTools() {
        let customRef = ToolReference.custom(definition: .init(
            id: "dynamic_tool",
            name: "dynamic_tool",
            description: "dynamic"
        ))
        let tool = AnyTool(CustomReferenceTool(
            id: "dynamic_tool",
            name: "dynamic_tool",
            toolReference: customRef
        ))

        let call = ParsedToolCall(callId: "1", name: "dynamic_tool", argumentsJSON: "{}")
        let resolved = ToolRoutingDecision.resolveToolReference(for: call, availableTools: [tool])

        #expect(resolved == customRef)
    }

    @Test("Attached workspaces defer unless timeline is private")
    func workspaceDispositionFollowsPrivacyRule() throws {
        #expect(try ToolRoutingDecision.outcomeForWorkspace(location: .attached, timelineIsPrivate: false) == .deferExternally)
        #expect(try ToolRoutingDecision.outcomeForWorkspace(location: .runtime, timelineIsPrivate: true) == .executeLocally)

        do {
            _ = try ToolRoutingDecision.outcomeForWorkspace(location: .attached, timelineIsPrivate: true)
            Issue.record("Expected attached-tools private-timeline error")
        } catch ToolError.attachedToolsDisallowedOnPrivateTimeline {
            // expected
        }
    }
}

struct ToolTurnProjectorTests {
    @Test("Completed outcomes persist tool messages and emit success events")
    func completedOutcomeProjection() async throws {
        let store = MockPersistenceService()
        let call = ParsedToolCall(callId: "call-1", name: "tool", argumentsJSON: "{}")

        let events = try await captureProjectedToolEvents { continuation in
            let message = try await ToolTurnProjector.projectOutcome(
                .completed("done"),
                call: call,
                timelineId: UUID(),
                logger: Logger(label: "test.projector"),
                messageStore: store,
                continuation: continuation
            )
            #expect(message?.content == "done")
        }

        #expect(store.messages.count == 1)
        #expect(store.messages.first?.content == "done")
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
        let store = MockPersistenceService()
        let call = ParsedToolCall(callId: "call-2", name: "tool", argumentsJSON: "{}")

        let events = try await captureProjectedToolEvents { continuation in
            let message = try await ToolTurnProjector.projectError(
                ToolError.executionFailed("boom"),
                call: call,
                toolRef: .known(id: "tool"),
                timelineId: UUID(),
                logger: Logger(label: "test.projector"),
                messageStore: store,
                continuation: continuation
            )
            #expect(message.content.contains("Error:"))
        }

        #expect(store.messages.count == 1)
        #expect(store.messages.first?.content.contains("Error:") == true)
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
            ToolError.toolNotFound("t").errorCode,
            ToolError.workspaceNotFound(UUID()).errorCode,
            ToolError.requestOriginUnavailable.errorCode,
            ToolError.attachedToolsDisallowedOnPrivateTimeline.errorCode,
            ToolError.permissionDenied("t").errorCode,
        ]
        #expect(codes.count == 10)
    }

    @Test("All v1 error categories have non-empty user-friendly messages")
    func nonEmptyUserFriendlyMessages() {
        let errors: [ToolError] = [
            .missingArgument("param"),
            .invalidArgument("param", expected: "Int", got: "String"),
            .malformedArguments("not JSON"),
            .schemaMismatch("missing required field"),
            .executionFailed("timeout"),
            .toolNotFound("unknown"),
            .workspaceNotFound(UUID()),
            .requestOriginUnavailable,
            .attachedToolsDisallowedOnPrivateTimeline,
            .permissionDenied("tool"),
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
            .toolNotFound("unknown"),
            .workspaceNotFound(UUID()),
            .requestOriginUnavailable,
            .attachedToolsDisallowedOnPrivateTimeline,
            .permissionDenied("tool"),
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
