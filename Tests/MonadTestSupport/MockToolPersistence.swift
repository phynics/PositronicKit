import MonadShared
import MonadCore
import Foundation

public final class MockToolPersistence: ToolPersistenceProtocol, @unchecked Sendable {
    public var workspaces: [WorkspaceReference] = []

    public init() {}

    public func addToolToWorkspace(workspaceId: UUID, tool: ToolReference) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            var ws = workspaces[index]
            ws.tools.append(tool)
            workspaces[index] = ws
        } else {
            throw ToolError.workspaceNotFound(workspaceId)
        }
    }

    public func syncTools(workspaceId: UUID, tools: [ToolReference]) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            var ws = workspaces[index]
            ws.tools = tools
            workspaces[index] = ws
        } else {
            throw ToolError.workspaceNotFound(workspaceId)
        }
    }

    public func fetchTools(forWorkspaces workspaceIds: [UUID]) async throws -> [ToolReference] {
        return workspaces.filter { workspaceIds.contains($0.id) }.flatMap { $0.tools }
    }

    public func fetchClientTools(clientId: UUID) async throws -> [ToolReference] {
        return workspaces.filter { $0.ownerId == clientId }.flatMap { $0.tools }
    }

    public func findWorkspaceId(forToolId toolId: String, in workspaceIds: [UUID]) async throws -> UUID? {
        for ws in workspaces where workspaceIds.contains(ws.id) {
            if ws.tools.contains(where: { $0.toolId == toolId }) {
                return ws.id
            }
        }
        return nil
    }

    public func fetchToolSource(toolId: String, workspaceIds: [UUID], primaryWorkspaceId: UUID?) async throws -> String? {
        guard let wsId = try await findWorkspaceId(forToolId: toolId, in: workspaceIds),
              let ws = workspaces.first(where: { $0.id == wsId })
        else { return nil }

        if ws.hostType == .client {
            return "Client Workspace"
        } else if ws.id == primaryWorkspaceId {
            return "Primary Workspace"
        } else {
            return "Workspace: \(ws.uri.description)"
        }
    }
}
