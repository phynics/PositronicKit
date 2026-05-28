import PKShared
import PositronicKit
import Foundation
import Synchronization

public final class MockToolPersistence: ToolPersistenceProtocol, @unchecked Sendable {
    private let workspacesState = Mutex<[WorkspaceReference]>([])

    public var workspaces: [WorkspaceReference] {
        get { workspacesState.withLock { $0 } }
        set { workspacesState.withLock { $0 = newValue } }
    }

    public init() {}

    public func addToolToWorkspace(workspaceId: UUID, tool: ToolReference) async throws {
        try workspacesState.withLock {
            guard let index = $0.firstIndex(where: { $0.id == workspaceId }) else {
                throw ToolError.workspaceNotFound(workspaceId)
            }

            var workspace = $0[index]
            workspace.tools.append(tool)
            $0[index] = workspace
        }
    }

    public func syncTools(workspaceId: UUID, tools: [ToolReference]) async throws {
        try workspacesState.withLock {
            guard let index = $0.firstIndex(where: { $0.id == workspaceId }) else {
                throw ToolError.workspaceNotFound(workspaceId)
            }

            var workspace = $0[index]
            workspace.tools = tools
            $0[index] = workspace
        }
    }

    public func fetchTools(forWorkspaces workspaceIds: [UUID]) async throws -> [ToolReference] {
        workspacesState.withLock {
            $0.filter { workspaceIds.contains($0.id) }.flatMap(\.tools)
        }
    }

    public func fetchOriginTools(originId: UUID) async throws -> [ToolReference] {
        workspacesState.withLock {
            $0.filter { $0.originId == originId }.flatMap(\.tools)
        }
    }

    public func findWorkspaceId(forToolId toolId: String, in workspaceIds: [UUID]) async throws -> UUID? {
        workspacesState.withLock {
            for workspace in $0 where workspaceIds.contains(workspace.id) {
                if workspace.tools.contains(where: { $0.toolId == toolId }) {
                    return workspace.id
                }
            }
            return nil
        }
    }

    public func fetchToolSource(toolId: String, workspaceIds: [UUID], primaryWorkspaceId: UUID?) async throws -> String? {
        workspacesState.withLock {
            guard let workspace = $0.first(where: { workspace in
                workspaceIds.contains(workspace.id)
                    && workspace.tools.contains { $0.toolId == toolId }
            }) else {
                return nil
            }

            if workspace.location == .attached {
                return "Additional Workspace"
            } else if workspace.id == primaryWorkspaceId {
                return "Primary Workspace"
            } else {
                return "Workspace: \(workspace.uri.description)"
            }
        }
    }
}
