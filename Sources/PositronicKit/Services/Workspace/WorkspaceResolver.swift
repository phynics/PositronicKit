import Foundation
import PKContracts
import PKUtilities

/// Resolves a Workspace ID to its active provider for the runtime.
///
/// This is the only operation the runtime needs. Cache lifecycle (eviction, health checks) belongs
/// to the concrete resolver; ``DefaultWorkspaceResolver`` exposes its own.
public protocol WorkspaceResolver: Sendable {
    /// Retrieves an active workspace provider by its ID, creating and caching it if necessary.
    func workspace(id: UUID) async throws -> any WorkspaceProvider?
}
