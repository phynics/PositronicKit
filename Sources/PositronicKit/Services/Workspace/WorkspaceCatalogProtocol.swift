import Foundation
import PKShared
import PKUtilities

/// Protocol for managing the persistence and provisioning of agent private workspaces.
public protocol WorkspaceCatalog: Sendable {
    /// Creates a new workspace and saves it to persistence.
    func createWorkspace(
        uri: WorkspaceURI,
        location: WorkspaceReference.WorkspaceLocation,
        originID: UUID?,
        rootPath: String?
    ) async throws -> WorkspaceReference

    /// Creates a new agent workspace and seeds it with template files.
    func createAgentWorkspace(
        instanceID: UUID,
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

public extension WorkspaceCatalog {
    /// Creates a workspace using the canonical identifier spelling.
    func createWorkspace(
        uri: WorkspaceURI,
        location: WorkspaceReference.WorkspaceLocation,
        originID: UUID? = nil,
        rootPath: String? = nil
    ) async throws -> WorkspaceReference {
        try await createWorkspace(
            uri: uri,
            location: location,
            originID: originID,
            rootPath: rootPath
        )
    }

    /// Creates an agent workspace using the canonical identifier spelling.
    func createAgentWorkspace(
        instanceID: UUID,
        template: AgentTemplate? = nil
    ) async throws -> WorkspaceReference {
        try await createAgentWorkspace(
            instanceID: instanceID,
            template: template
        )
    }

    func getWorkspace(id: UUID, includeTools: Bool = true) async throws -> WorkspaceReference? {
        try await getWorkspace(id: id, includeTools: includeTools)
    }

    func deleteWorkspace(id: UUID, deleteDirectory: Bool = false) async throws {
        try await deleteWorkspace(id: id, deleteDirectory: deleteDirectory)
    }
}
