import Foundation
import PKContracts

/// Workspace catalog entry points exposed by ``PositronicKit``.
public struct WorkspaceCapability: Sendable {
    private let kit: PositronicKit

    init(kit: PositronicKit) {
        self.kit = kit
    }

    /// Creates and persists a workspace reference.
    ///
    /// - Parameters:
    ///   - uri: Stable URI identifying the workspace.
    ///   - location: Whether the workspace is runtime-owned or attached.
    ///   - originID: Optional Agent or Thread origin for the workspace.
    ///   - rootPath: Optional filesystem root for filesystem-backed workspaces.
    /// - Returns: The persisted workspace reference.
    public func create(
        uri: WorkspaceURI,
        location: WorkspaceReference.WorkspaceLocation,
        originID: UUID? = nil,
        rootPath: String? = nil
    ) async throws -> WorkspaceReference {
        try await kit.workspaceCatalog.createWorkspace(
            uri: uri,
            location: location,
            originID: originID,
            rootPath: rootPath
        )
    }

    /// Fetches a workspace reference by ID.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace to fetch.
    ///   - includeTools: Whether tool metadata should be included.
    /// - Returns: The workspace reference, or `nil` when no workspace has that ID.
    public func fetch(_ workspaceID: UUID, includeTools: Bool = true) async throws -> WorkspaceReference? {
        try await kit.workspaceCatalog.fetchWorkspace(workspaceID: workspaceID, includeTools: includeTools)
    }

    /// Lists all persisted workspaces.
    ///
    /// - Returns: Workspace references in persistence order.
    public func list() async throws -> [WorkspaceReference] {
        try await kit.workspaceCatalog.listWorkspaces()
    }

    /// Updates a persisted workspace reference.
    ///
    /// - Parameter workspace: The complete replacement reference.
    public func update(_ workspace: WorkspaceReference) async throws {
        try await kit.workspaceCatalog.updateWorkspace(workspace)
    }

    /// Deletes a workspace and, when requested, its runtime-owned directory.
    ///
    /// - Parameter workspaceID: The workspace to delete.
    /// - Parameter includingDirectory: If `true`, also removes the workspace directory when the
    ///   workspace is runtime-owned. Attached workspaces reject directory deletion.
    public func delete(_ workspaceID: UUID, includingDirectory: Bool = false) async throws {
        try await kit.workspaceCatalog.deleteWorkspace(
            workspaceID: workspaceID,
            includingDirectory: includingDirectory
        )
    }
}
