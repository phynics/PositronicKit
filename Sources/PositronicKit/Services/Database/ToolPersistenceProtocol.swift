import PKContracts
import PKUtilities
/// Persists tool registrations and routing metadata within workspace scope.
///
/// `addToolToWorkspace` and `syncTools` require the workspace to exist; the concrete error type
/// is an implementation detail unless a conformer documents a stronger error contract.
/// `syncTools` atomically replaces the complete tool set for one workspace. Queries respect the
/// supplied workspace IDs, origin IDs filter by workspace ownership, and owner lookup never
/// escapes the supplied scope. A known in-scope tool has a non-`nil` source presentation; an
/// unknown or out-of-scope tool returns `nil`. The exact source string is deliberately not part
/// of the protocol contract.

import Foundation

public protocol ToolPersistenceProtocol: DurabilityAware {
    func addToolToWorkspace(workspaceId: UUID, tool: ToolReference) async throws
    /// Atomically replaces all tools for a workspace with the provided set.
    /// Use this when a workspace provider connects to push its current tool list.
    /// Existing tool IDs not present in the new list are removed; new ones are inserted.
    func syncTools(workspaceId: UUID, tools: [ToolReference]) async throws
    func fetchTools(forWorkspaces workspaceIds: [UUID]) async throws -> [ToolReference]
    func fetchOriginTools(originId: UUID) async throws -> [ToolReference]
    func findWorkspaceId(forToolId toolId: String, in workspaceIds: [UUID]) async throws -> UUID?
    func fetchToolSource(toolId: String, workspaceIds: [UUID], primaryWorkspaceId: UUID?    ) async throws -> String?
}
