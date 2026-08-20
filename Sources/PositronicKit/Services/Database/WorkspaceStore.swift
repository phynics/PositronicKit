import PKContracts
import PKUtilities

// Protocol for managing virtual document workspaces.

import Foundation

public protocol WorkspaceStore: DurabilityAware {
    func saveWorkspace(_ workspace: WorkspaceReference) async throws
    func fetchWorkspace(id: UUID, includeTools: Bool) async throws -> WorkspaceReference?
    func fetchAllWorkspaces() async throws -> [WorkspaceReference]
    func deleteWorkspace(id: UUID) async throws
}
