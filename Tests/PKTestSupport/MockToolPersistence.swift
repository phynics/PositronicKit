import PKShared
import PositronicKit
import Foundation

public final class MockToolPersistence: ToolPersistenceProtocol, @unchecked Sendable {
    private let backing = InMemoryToolPersistence()

    public var workspaces: [WorkspaceReference] {
        get { (try? BlockingAsync.run { [self] in await self.backing.allWorkspaces() }) ?? [] }
        set { _ = try? BlockingAsync.run { [self] in await self.backing.replaceWorkspaces(newValue) } }
    }

    public init() {}

    public func addToolToWorkspace(workspaceId: UUID, tool: ToolReference) async throws {
        try await backing.addToolToWorkspace(workspaceId: workspaceId, tool: tool)
    }

    public func syncTools(workspaceId: UUID, tools: [ToolReference]) async throws {
        try await backing.syncTools(workspaceId: workspaceId, tools: tools)
    }

    public func fetchTools(forWorkspaces workspaceIds: [UUID]) async throws -> [ToolReference] {
        try await backing.fetchTools(forWorkspaces: workspaceIds)
    }

    public func fetchOriginTools(originId: UUID) async throws -> [ToolReference] {
        try await backing.fetchOriginTools(originId: originId)
    }

    public func findWorkspaceId(forToolId toolId: String, in workspaceIds: [UUID]) async throws -> UUID? {
        try await backing.findWorkspaceId(forToolId: toolId, in: workspaceIds)
    }

    public func fetchToolSource(toolId: String, workspaceIds: [UUID], primaryWorkspaceId: UUID?) async throws -> String? {
        try await backing.fetchToolSource(toolId: toolId, workspaceIds: workspaceIds, primaryWorkspaceId: primaryWorkspaceId)
    }
}
