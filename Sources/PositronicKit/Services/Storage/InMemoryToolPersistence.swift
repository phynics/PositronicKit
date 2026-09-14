import Foundation
import PKContracts
import PKUtilities

/// Timeline-safe in-memory tool persistence for prototyping and development.
public actor InMemoryToolPersistence: ToolPersistenceProtocol {
    private var workspaces: [WorkspaceReference] = []

    public init() {}

    public func addToolToWorkspace(workspaceID: UUID, tool: ToolReference) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspaceID }) {
            var workspace = workspaces[index]
            workspace.tools.append(tool)
            workspaces[index] = workspace
        } else {
            throw ToolError.workspaceNotFound(workspaceID)
        }
    }

    public func syncTools(workspaceID: UUID, tools: [ToolReference]) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspaceID }) {
            var workspace = workspaces[index]
            workspace.tools = tools
            workspaces[index] = workspace
        } else {
            throw ToolError.workspaceNotFound(workspaceID)
        }
    }

    public func fetchTools(forWorkspaces workspaceIDs: [UUID]) async throws -> [ToolReference] {
        workspaces.filter { workspaceIDs.contains($0.id) }.flatMap(\.tools)
    }

    public func fetchOriginTools(originID: UUID) async throws -> [ToolReference] {
        workspaces.filter { $0.originID == originID }.flatMap(\.tools)
    }

    public func findWorkspace(hostingToolNamed toolName: String, in workspaceIDs: [UUID]) async throws -> UUID? {
        for workspace in workspaces where workspaceIDs.contains(workspace.id) {
            if workspace.tools.contains(where: { $0.toolID == toolName }) {
                return workspace.id
            }
        }
        return nil
    }

    public func fetchToolSource(
        named toolName: String, in workspaceIDs: [UUID], preferring primaryWorkspaceID: UUID?
    ) async throws -> String? {
        guard let wsId = try await findWorkspace(hostingToolNamed: toolName, in: workspaceIDs),
              let workspace = workspaces.first(where: { $0.id == wsId })
        else { return nil }

        if workspace.location == .attached {
            return "Additional Workspace"
        } else if workspace.id == primaryWorkspaceID {
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
