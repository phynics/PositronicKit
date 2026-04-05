import Foundation
import MonadShared

/// Protocol for managing the persistence and provisioning of agent private workspaces.
public protocol AgentWorkspaceServiceProtocol: Sendable {
    /// Creates a new workspace and saves it to persistence.
    func createWorkspace(
        uri: WorkspaceURI,
        hostType: WorkspaceReference.WorkspaceHostType,
        ownerId: UUID?,
        rootPath: String?,
        metadata: [String: AnyCodable]
    ) async throws -> WorkspaceReference

    /// Creates a new agent workspace and seeds it with template files.
    func createAgentWorkspace(
        instanceId: UUID,
        template: AgentTemplate?,
        metadata: [String: AnyCodable]
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
        hostType: WorkspaceReference.WorkspaceHostType,
        ownerId: UUID? = nil,
        rootPath: String? = nil,
        metadata: [String: AnyCodable] = [:]
    ) async throws -> WorkspaceReference {
        try await createWorkspace(
            uri: uri,
            hostType: hostType,
            ownerId: ownerId,
            rootPath: rootPath,
            metadata: metadata
        )
    }

    public func createAgentWorkspace(
        instanceId: UUID,
        template: AgentTemplate? = nil,
        metadata: [String: AnyCodable] = [:]
    ) async throws -> WorkspaceReference {
        try await createAgentWorkspace(
            instanceId: instanceId,
            template: template,
            metadata: metadata
        )
    }

    public func getWorkspace(id: UUID, includeTools: Bool = true) async throws -> WorkspaceReference? {
        try await getWorkspace(id: id, includeTools: includeTools)
    }

    public func deleteWorkspace(id: UUID, deleteDirectory: Bool = false) async throws {
        try await deleteWorkspace(id: id, deleteDirectory: deleteDirectory)
    }
}
