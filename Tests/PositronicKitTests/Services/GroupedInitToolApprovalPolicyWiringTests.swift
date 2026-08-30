import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// Regression coverage for PKAPI-008: the grouped `PositronicKit` initializers that take a
/// `RuntimeConfiguration` (and the persistence-grouped initializer) must thread their
/// `toolApprovalPolicy` through to the facade-built `ToolRouter`, rather than silently dropping
/// it in favor of `DenyAllToolApprovalPolicy`. A host integrating via the "recommended" grouped
/// API must be able to inject a real approver without dropping to the flat initializer.
///
/// The fixtures (`PermissionedTool`, `RecordingGate`) mirror the ones already established in
/// `ToolRouterTests.swift` / `ToolApprovalPolicyFilesystemToolsTests.swift`; they are duplicated
/// here for the same reason those suites duplicate them — the helpers are `private` to their
/// own files and there is no shared PKTestSupport extension point for them yet.
@Suite("Grouped init toolApprovalPolicy wiring")
struct GroupedInitToolApprovalPolicyWiringTests {
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

        func canExecute() async -> Bool { true }

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

    /// Builds a facade via the grouped `runtime:` initializer with the given gate, registers a
    /// single permissioned tool in an attached workspace, and returns the facade, thread id,
    /// and tool so the test can drive `chat.toolRouter.execute(...)` directly.
    private func makeChatViaRuntimeConfig(
        gate: any ToolApprovalPolicy
    ) async throws -> (PositronicKit, UUID, PermissionedTool) {
        let tool = PermissionedTool(id: "needs_permission")
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()

        let persistence = PositronicKit.PersistenceConfiguration(
            runtimeRepository: mockPersistence,
            workspacePersistence: mockPersistence,
            toolPersistence: mockPersistence,
            agentStore: mockPersistence,
            requestOriginStore: mockPersistence
        )
        let chat = PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService()),
            persistence: persistence,
            runtime: .init(
                workspaceProfile: .hostManaged(root: workspace.root),
                workspaceCreator: MockWorkspaceCreator(),
                toolApprovalPolicy: gate
            )
        ))
        let threadID = try await register(tool, on: chat, persistence: mockPersistence)
        return (chat, threadID, tool)
    }

    /// Builds a facade via the persistence-grouped initializer (no `RuntimeConfiguration`),
    /// passing `toolApprovalPolicy` as a direct parameter, to confirm that overload threads it
    /// through as well.
    private func makeChatViaPersistenceGroupedInit(
        gate: any ToolApprovalPolicy
    ) async throws -> (PositronicKit, UUID, PermissionedTool) {
        let tool = PermissionedTool(id: "needs_permission")
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()

        let persistence = PositronicKit.PersistenceConfiguration(
            runtimeRepository: mockPersistence,
            workspacePersistence: mockPersistence,
            toolPersistence: mockPersistence,
            agentStore: mockPersistence,
            requestOriginStore: mockPersistence
        )
        let chat = PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService()),
            persistence: persistence,
            runtime: .init(workspaceProfile: .hostManaged(root: workspace.root), toolApprovalPolicy: gate)
        ))
        let threadID = try await register(tool, on: chat, persistence: mockPersistence)
        return (chat, threadID, tool)
    }

    /// Creates a thread on `chat.threadManager`, attaches a runtime workspace, and registers
    /// the permissioned tool in it so `chat.toolRouter` can resolve and execute it.
    private func register(
        _ tool: PermissionedTool,
        on chat: PositronicKit,
        persistence mockPersistence: MockPersistenceService
    ) async throws -> UUID {
        let thread = try await chat.threadManager.createThread()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://local")),
            location: .runtime,
            originID: nil
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await chat.threadManager.attachWorkspace(workspaceId, to: thread.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(tool.callName))

        let toolManager = try #require(await chat.threadManager.getToolManager(for: thread.id))
        await toolManager.updateAvailableTools([tool.toAnyTool()])
        return thread.id
    }

    // MARK: - RuntimeConfiguration path

    @Test("Grouped runtime init honors an injected deny gate (permissioned tool blocked)")
    func groupedRuntimeInitHonorsInjectedDenyGate() async throws {
        let gate = RecordingGate(decision: .deny)
        let (chat, threadID, tool) = try await makeChatViaRuntimeConfig(gate: gate)

        do {
            _ = try await chat.toolRouter.execute(
                tool: .known(tool.callName),
                arguments: [:],
                threadID: threadID,
                availableTools: [tool.toAnyTool()]
            )
            Issue.record("Expected permissionDenied to be thrown")
        } catch ToolError.permissionDenied(tool.name) {
            // expected — the injected gate's decision was honored, not the default
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(tool.didExecute == false)
        #expect(gate.consultedToolIds == [tool.callName])
    }

    @Test("Grouped runtime init honors an injected approve gate (permissioned tool runs)")
    func groupedRuntimeInitHonorsInjectedApproveGate() async throws {
        let gate = RecordingGate(decision: .approve)
        let (chat, threadID, tool) = try await makeChatViaRuntimeConfig(gate: gate)

        let result = try await chat.toolRouter.execute(
            tool: .known(tool.callName),
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
        #expect(gate.consultedToolIds == [tool.callName])
    }

    // MARK: - Persistence-grouped init path

    @Test("Persistence-grouped init honors an injected deny gate (permissioned tool blocked)")
    func persistenceGroupedInitHonorsInjectedDenyGate() async throws {
        let gate = RecordingGate(decision: .deny)
        let (chat, threadID, tool) = try await makeChatViaPersistenceGroupedInit(gate: gate)

        do {
            _ = try await chat.toolRouter.execute(
                tool: .known(tool.callName),
                arguments: [:],
                threadID: threadID,
                availableTools: [tool.toAnyTool()]
            )
            Issue.record("Expected permissionDenied to be thrown")
        } catch ToolError.permissionDenied(tool.name) {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(tool.didExecute == false)
        #expect(gate.consultedToolIds == [tool.callName])
    }

    @Test("Persistence-grouped init honors an injected approve gate (permissioned tool runs)")
    func persistenceGroupedInitHonorsInjectedApproveGate() async throws {
        let gate = RecordingGate(decision: .approve)
        let (chat, threadID, tool) = try await makeChatViaPersistenceGroupedInit(gate: gate)

        let result = try await chat.toolRouter.execute(
            tool: .known(tool.callName),
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
        #expect(gate.consultedToolIds == [tool.callName])
    }
}
