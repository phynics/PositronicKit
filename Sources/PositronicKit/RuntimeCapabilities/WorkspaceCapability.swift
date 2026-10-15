import Foundation
import PKContracts

/// Workspace catalog entry points exposed by ``PKRuntime``.
public struct WorkspaceCapability: Sendable {
    private let workspaceCatalog: any WorkspaceCatalog
    private let attachWorkspaceToTimeline: @Sendable (UUID, UUID) async throws -> Void

    init(
        workspaceCatalog: any WorkspaceCatalog,
        attachWorkspaceToTimeline: @escaping @Sendable (UUID, UUID) async throws -> Void = { _, _ in
            throw WorkspaceError.toolExecutionNotSupported
        }
    ) {
        self.workspaceCatalog = workspaceCatalog
        self.attachWorkspaceToTimeline = attachWorkspaceToTimeline
    }

    public func create(
        uri: WorkspaceURI,
        location: WorkspaceReference.WorkspaceLocation,
        originID: UUID? = nil,
        rootPath: String? = nil
    ) async throws -> WorkspaceReference {
        try await workspaceCatalog.createWorkspace(
            uri: uri,
            location: location,
            originID: originID,
            rootPath: rootPath
        )
    }

    /// Creates a workspace with host-owned metadata and persists it.
    ///
    /// A ``WorkspaceFactory`` adapter uses the metadata to rebuild a live provider. The runtime
    /// never interprets it. Values must not contain secret material.
    public func create(
        uri: WorkspaceURI,
        location: WorkspaceReference.WorkspaceLocation,
        originID: UUID? = nil,
        rootPath: String? = nil,
        metadata: [String: AnyCodable]?
    ) async throws -> WorkspaceReference {
        try await workspaceCatalog.createWorkspace(
            uri: uri,
            location: location,
            originID: originID,
            rootPath: rootPath,
            metadata: metadata
        )
    }

    /// Creates a workspace and binds it to a Timeline in one operation.
    ///
    /// The workspace is created first, then attached through the same durable conditional-claim
    /// boundary as ``TimelineCapability/attachWorkspace(_:to:)``. A failed attach leaves the
    /// persisted workspace unbound; the caller may retry or delete it.
    public func createAndAttach(
        uri: WorkspaceURI,
        location: WorkspaceReference.WorkspaceLocation,
        to timelineID: UUID,
        rootPath: String? = nil,
        metadata: [String: AnyCodable]? = nil
    ) async throws -> WorkspaceReference {
        let reference = try await create(
            uri: uri,
            location: location,
            rootPath: rootPath,
            metadata: metadata
        )
        try await attachWorkspaceToTimeline(reference.id, timelineID)
        return reference
    }

    public func get(_ workspaceID: UUID, includeTools: Bool = true) async throws -> WorkspaceReference? {
        try await workspaceCatalog.fetchWorkspace(id: workspaceID, includeTools: includeTools)
    }

    public func list() async throws -> [WorkspaceReference] {
        try await workspaceCatalog.listWorkspaces()
    }

    public func update(_ workspace: WorkspaceReference) async throws {
        try await workspaceCatalog.updateWorkspace(workspace)
    }

    public func delete(_ workspaceID: UUID, includingDirectory: Bool = false) async throws {
        try await workspaceCatalog.deleteWorkspace(
            id: workspaceID,
            includingDirectory: includingDirectory
        )
    }
}
