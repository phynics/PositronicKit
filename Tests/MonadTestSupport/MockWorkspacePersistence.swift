import Foundation
import MonadCore
import MonadShared

public final class MockWorkspacePersistence: WorkspacePersistenceProtocol, @unchecked Sendable {
    public var workspaces: [WorkspaceReference] = []

    public init() {}

    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    public func fetchWorkspace(id: UUID, includeTools _: Bool = false) async throws -> WorkspaceReference? {
        return workspaces.first(where: { $0.id == id })
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        return workspaces
    }

    public func deleteWorkspace(id: UUID) async throws {
        workspaces.removeAll(where: { $0.id == id })
    }
}
