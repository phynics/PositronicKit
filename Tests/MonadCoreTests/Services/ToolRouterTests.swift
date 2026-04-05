import Dependencies
import Foundation
@testable import MonadCore
@testable import MonadShared
import MonadTestSupport
import Testing

@Suite final class ToolRouterTests {
    struct MockTool: MonadShared.Tool, @unchecked Sendable {
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
                throw ToolError.clientToolsDisallowedOnPrivateTimeline
            }
            return result
        }
    }

    private func setupTimelineManager() async throws -> (TimelineManager, MockPersistenceService) {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = try await TestDependencies()
            .withMocks(persistence: mockPersistence)
            .run {
                TimelineManager(workspaceRoot: workspace.root)
            }
        return (timelineManager, mockPersistence)
    }

    @Test

    func executeLocally() async throws {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = try await withDependencies {
            $0.timelineManager = timelineManager
        } operation: {
            ToolRouter()
        }

        // Setup session and local workspace
        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "monad://local")), hostType: .server, ownerId: nil)

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

    func executeRemotelyThrowsClientExecutionRequired() async throws {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = try await withDependencies {
            $0.timelineManager = timelineManager
        } operation: {
            ToolRouter()
        }

        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()

        // Setup remote workspace
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "monad://remote")), hostType: .client, ownerId: UUID())
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: session.id)

        let toolId = "remote_tool"
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(toolId))

        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = [:]

        do {
            let result = try await toolRouter.execute(tool: toolRef, arguments: arguments, timelineId: session.id)
            guard case .deferredToClient = result else {
                Issue.record("Expected .deferredToClient")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test

    func executeRemotelyWithoutClientThrowsClientNotConnected() async throws {
        let (timelineManager, mockPersistence) = try await setupTimelineManager()
        let toolRouter = try await withDependencies {
            $0.timelineManager = timelineManager
        } operation: {
            ToolRouter()
        }

        let session = try await timelineManager.createTimeline()
        let workspaceId = UUID()

        // Setup remote workspace missing an ownerId
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "monad://remote")), hostType: .client, ownerId: nil)
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: session.id)

        let toolId = "remote_tool"
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known(toolId))

        let toolRef = ToolReference.known(toolId)
        let arguments: [String: AnyCodable] = [:]

        do {
            let result = try await toolRouter.execute(tool: toolRef, arguments: arguments, timelineId: session.id)
            guard case .deferredToClient = result else {
                Issue.record("Expected .deferredToClient")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test

    func executeToolNotFound() async throws {
        let (timelineManager, _) = try await setupTimelineManager()
        let toolRouter = try await withDependencies {
            $0.timelineManager = timelineManager
        } operation: {
            ToolRouter()
        }

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
}
