import PKContracts
import PKUtilities

/// Persists the authoritative metadata for virtual document workspaces.
///
/// A conformer must upsert by `WorkspaceReference.id`. Fetching an unknown ID returns `nil`,
/// fetching all workspaces returns every stored ID, and deletion targets only the requested ID.
/// Deleting an unknown ID is idempotent. `includeTools` is caller-controlled projection context;
/// the universal contract requires the requested workspace identity, but does not prescribe how
/// a conformer obtains or projects its tools.

import Foundation

public protocol WorkspaceStore: DurabilityAware {
    func saveWorkspace(_ workspace: WorkspaceReference) async throws
    func fetchWorkspace(id: UUID, includeTools: Bool) async throws -> WorkspaceReference?
    func fetchAllWorkspaces() async throws -> [WorkspaceReference]
    func deleteWorkspace(id: UUID) async throws
}
