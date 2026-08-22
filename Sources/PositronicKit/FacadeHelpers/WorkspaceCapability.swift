import Foundation
import PKContracts

/// Workspace catalog entry points exposed by ``PositronicKit``.
public struct WorkspaceCapability: Sendable {
    private let kit: PositronicKit

    init(kit: PositronicKit) {
        self.kit = kit
    }

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

    public func get(_ workspaceID: UUID, includeTools: Bool = true) async throws -> WorkspaceReference? {
        try await kit.workspaceCatalog.getWorkspace(id: workspaceID, includeTools: includeTools)
    }

    public func list() async throws -> [WorkspaceReference] {
        try await kit.workspaceCatalog.listWorkspaces()
    }

    public func update(_ workspace: WorkspaceReference) async throws {
        try await kit.workspaceCatalog.updateWorkspace(workspace)
    }

    public func delete(_ workspaceID: UUID, deleteDirectory: Bool = false) async throws {
        try await kit.workspaceCatalog.deleteWorkspace(
            id: workspaceID,
            deleteDirectory: deleteDirectory
        )
    }
}
