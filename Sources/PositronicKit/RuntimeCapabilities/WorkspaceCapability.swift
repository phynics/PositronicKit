import Foundation
import PKContracts

/// Workspace catalog entry points exposed by ``PKRuntime``.
public struct WorkspaceCapability: Sendable {
    private let workspaceCatalog: any WorkspaceCatalog

    init(workspaceCatalog: any WorkspaceCatalog) {
        self.workspaceCatalog = workspaceCatalog
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
