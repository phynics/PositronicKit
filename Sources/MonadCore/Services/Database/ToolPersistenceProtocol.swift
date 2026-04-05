import MonadShared
/// Protocol for managing tool registrations and routing metadata.

import Foundation

public protocol ToolPersistenceProtocol: Sendable {
    func addToolToWorkspace(workspaceId: UUID, tool: ToolReference) async throws
    /// Atomically replaces all tools for a workspace with the provided set.
    /// Use this when a workspace provider connects to push its current tool list.
    /// Existing tool IDs not present in the new list are removed; new ones are inserted.
    func syncTools(workspaceId: UUID, tools: [ToolReference]) async throws
    func fetchTools(forWorkspaces workspaceIds: [UUID]) async throws -> [ToolReference]
    func fetchClientTools(clientId: UUID) async throws -> [ToolReference]
    func findWorkspaceId(forToolId toolId: String, in workspaceIds: [UUID]) async throws -> UUID?
    func fetchToolSource(toolId: String, workspaceIds: [UUID], primaryWorkspaceId: UUID?) async throws -> String?
}
