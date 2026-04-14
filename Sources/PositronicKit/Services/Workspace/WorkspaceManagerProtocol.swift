import Foundation
import PKShared

/// Protocol for managing the lifecycle of active Workspace instances.
public protocol WorkspaceManagerProtocol: Sendable {
    /// Returns the number of currently active/cached workspaces.
    var activeWorkspaceCount: Int { get async }

    /// Retrieves an active workspace instance by its ID, creating and caching it if necessary.
    func getWorkspace(id: UUID) async throws -> (any WorkspaceProtocol)?

    /// Closes and removes a workspace from the active cache.
    func closeWorkspace(id: UUID) async

    /// Performs a health check on all active workspaces, evicting any that are unhealthy.
    func healthCheckAll() async -> [UUID: Bool]
}
