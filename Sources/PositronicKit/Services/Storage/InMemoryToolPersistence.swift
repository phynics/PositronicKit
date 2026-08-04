import Foundation
import PKShared
import PKUtilities

/// Thread-safe in-memory tool persistence for prototyping and development.
public actor InMemoryToolPersistence: ToolPersistenceProtocol {
    private var workspaces: [WorkspaceReference] = []

    public init() {}

    public func addToolToWorkspace(workspaceId: UUID, tool: ToolReference) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            var workspace = workspaces[index]
            workspace.tools.append(tool)
            workspaces[index] = workspace
        } else {
            throw ToolError.workspaceNotFound(workspaceId)
        }
    }

    public func syncTools(workspaceId: UUID, tools: [ToolReference]) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            var workspace = workspaces[index]
            workspace.tools = tools
            workspaces[index] = workspace
        } else {
            throw ToolError.workspaceNotFound(workspaceId)
        }
    }

    public func fetchTools(forWorkspaces workspaceIds: [UUID]) async throws -> [ToolReference] {
        workspaces.filter { workspaceIds.contains($0.id) }.flatMap(\.tools)
    }

    public func fetchOriginTools(originId: UUID) async throws -> [ToolReference] {
        workspaces.filter { $0.originID == originId }.flatMap(\.tools)
    }

    public func findWorkspaceId(forToolId toolId: String, in workspaceIds: [UUID]) async throws -> UUID? {
        for workspace in workspaces where workspaceIds.contains(workspace.id) {
            if workspace.tools.contains(where: { $0.toolID == toolId }) {
                return workspace.id
            }
        }
        return nil
    }

    public func fetchToolSource(
        toolId: String, workspaceIds: [UUID], primaryWorkspaceId: UUID?
    ) async throws -> String? {
        guard let wsId = try await findWorkspaceId(forToolId: toolId, in: workspaceIds),
              let workspace = workspaces.first(where: { $0.id == wsId })
        else { return nil }

        if workspace.location == .attached {
            return "Additional Workspace"
        } else if workspace.id == primaryWorkspaceId {
            return "Primary Workspace"
        } else {
            return "Workspace: \(workspace.uri.description)"
        }
    }

    package func allWorkspaces() -> [WorkspaceReference] {
        workspaces
    }

    package func replaceWorkspaces(_ workspaces: [WorkspaceReference]) {
        self.workspaces = workspaces
    }
}
