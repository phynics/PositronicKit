import Foundation
import PositronicKit
import PKShared
import Synchronization

public final class MockWorkspacePersistence: WorkspacePersistenceProtocol, @unchecked Sendable {
    private let workspacesState = Mutex<[WorkspaceReference]>([])

    public var workspaces: [WorkspaceReference] {
        get { workspacesState.withLock { $0 } }
        set { workspacesState.withLock { $0 = newValue } }
    }

    public init() {}

    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        workspacesState.withLock {
            if let index = $0.firstIndex(where: { $0.id == workspace.id }) {
                $0[index] = workspace
            } else {
                $0.append(workspace)
            }
        }
    }

    public func fetchWorkspace(id: UUID, includeTools _: Bool = false) async throws -> WorkspaceReference? {
        workspacesState.withLock {
            $0.first { $0.id == id }
        }
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        workspacesState.withLock { $0 }
    }

    public func deleteWorkspace(id: UUID) async throws {
        workspacesState.withLock {
            $0.removeAll { $0.id == id }
        }
    }
}
