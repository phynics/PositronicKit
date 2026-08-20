import Foundation
import PKContracts
import PKUtilities

/// Thread-safe in-memory workspace persistence for prototyping and development.
public actor InMemoryWorkspacePersistence: WorkspaceStore {
    private var workspaces: [WorkspaceReference] = []

    public init() {}

    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    public func fetchWorkspace(id: UUID, includeTools _: Bool = false) async throws -> WorkspaceReference? {
        workspaces.first { $0.id == id }
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        workspaces
    }

    public func deleteWorkspace(id: UUID) async throws {
        workspaces.removeAll { $0.id == id }
    }

    package func allWorkspaces() -> [WorkspaceReference] {
        workspaces
    }

    package func replaceWorkspaces(_ workspaces: [WorkspaceReference]) {
        self.workspaces = workspaces
    }
}
