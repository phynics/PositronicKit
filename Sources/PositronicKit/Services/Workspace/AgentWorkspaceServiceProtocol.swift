import Foundation
import PKShared

/// Protocol for managing the persistence and provisioning of agent private workspaces.
public protocol AgentWorkspaceServiceProtocol: Sendable {
    /// Creates a new workspace and saves it to persistence.
    func createWorkspace(
        uri: WorkspaceURI,
        location: WorkspaceReference.WorkspaceLocation,
        originId: UUID?,
        rootPath: String?
    ) async throws -> WorkspaceReference

    /// Creates a new agent workspace and seeds it with template files.
    func createAgentWorkspace(
        instanceId: UUID,
        template: AgentTemplate?
    ) async throws -> WorkspaceReference

    /// Fetches a workspace by its unique identifier.
    func getWorkspace(id: UUID, includeTools: Bool) async throws -> WorkspaceReference?

    /// Lists all workspaces.
    func listWorkspaces() async throws -> [WorkspaceReference]

    /// Deletes a workspace.
    func deleteWorkspace(id: UUID, deleteDirectory: Bool) async throws

    /// Updates an existing workspace.
    func updateWorkspace(_ workspace: WorkspaceReference) async throws
}

extension AgentWorkspaceServiceProtocol {
    public func createWorkspace(
        uri: WorkspaceURI,
        location: WorkspaceReference.WorkspaceLocation,
        originId: UUID? = nil,
        rootPath: String? = nil
    ) async throws -> WorkspaceReference {
        try await createWorkspace(
            uri: uri,
            location: location,
            originId: originId,
            rootPath: rootPath
        )
    }

    public func createAgentWorkspace(
        instanceId: UUID,
        template: AgentTemplate? = nil
    ) async throws -> WorkspaceReference {
        try await createAgentWorkspace(
            instanceId: instanceId,
            template: template
        )
    }

    public func getWorkspace(id: UUID, includeTools: Bool = true) async throws -> WorkspaceReference? {
        try await getWorkspace(id: id, includeTools: includeTools)
    }

    public func deleteWorkspace(id: UUID, deleteDirectory: Bool = false) async throws {
        try await deleteWorkspace(id: id, deleteDirectory: deleteDirectory)
    }
}
