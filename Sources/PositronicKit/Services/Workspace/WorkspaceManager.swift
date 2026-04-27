import Foundation
import Logging
import PKShared

/// Manages the lifecycle of active Workspace instances.
///
/// WorkspaceManager is responsible for resolving WorkspaceReferences into concrete
/// WorkspaceProtocol implementations, maintaining a cache of active workspaces,
/// and coordinating their lifecycle (creation, health checks, and shutdown).
public actor WorkspaceManager: WorkspaceManagerProtocol {
    private let repository: any AgentWorkspaceServiceProtocol
    private let workspaceCreator: any WorkspaceCreating

    /// Cache of active workspace instances.
    private var activeWorkspaces: [UUID: any WorkspaceProtocol] = [:]

    public init(
        repository: any AgentWorkspaceServiceProtocol,
        workspaceCreator: any WorkspaceCreating
    ) {
        self.repository = repository
        self.workspaceCreator = workspaceCreator
    }

    /// Returns the number of currently active/cached workspaces.
    public var activeWorkspaceCount: Int {
        activeWorkspaces.count
    }

    /// Retrieves an active workspace instance by its ID, creating and caching it if necessary.
    public func getWorkspace(id: UUID) async throws -> (any WorkspaceProtocol)? {
        // Check cache first
        if let active = activeWorkspaces[id] {
            return active
        }

        // Fetch from repository
        guard let reference = try await repository.getWorkspace(id: id) else {
            return nil
        }

        // Create concrete implementation via injected creator
        let workspace = try workspaceCreator.create(from: reference)

        // Cache and return
        activeWorkspaces[id] = workspace
        return workspace
    }

    /// Closes and removes a workspace from the active cache.
    public func closeWorkspace(id: UUID) async {
        activeWorkspaces.removeValue(forKey: id)
    }

    /// Performs a health check on all active workspaces, evicting any that are unhealthy.
    public func healthCheckAll() async -> [UUID: Bool] {
        var results: [UUID: Bool] = [:]
        for (id, workspace) in activeWorkspaces {
            let healthy = await workspace.healthCheck()
            results[id] = healthy
            if !healthy {
                activeWorkspaces.removeValue(forKey: id)
            }
        }
        return results
    }
}
