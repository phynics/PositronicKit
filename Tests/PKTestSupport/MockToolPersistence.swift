import Foundation
import PKContracts
import PKUtilities
import PositronicKit
import Synchronization

/// In-memory `ToolPersistenceProtocol` test double, storing tools as `tools` arrays on a
/// mutex-guarded set of `WorkspaceReference`s (mirroring how tools are actually persisted
/// as part of their owning workspace).
///
/// Inspectable: `workspaces` reads/writes the backing store directly, so tests can seed
/// workspaces (with tools already attached) or assert on saved state. Mutating a workspace
/// not present in `workspaces` throws `ToolError.workspaceNotFound`. Inserts, replacements, and
/// tool-array mutations each occur in one mutex transaction.
public final class MockToolPersistence: ToolPersistenceProtocol {
    private let workspacesState = Mutex<[WorkspaceReference]>([])

    public var workspaces: [WorkspaceReference] {
        get { workspacesState.withLock { $0 } }
        set { workspacesState.withLock { $0 = newValue } }
    }

    public init() {}

    /// Inserts or replaces a workspace in one atomic mutation.
    public func upsertWorkspace(_ workspace: WorkspaceReference) {
        workspacesState.withLock {
            if let index = $0.firstIndex(where: { $0.id == workspace.id }) {
                $0[index] = workspace
            } else {
                $0.append(workspace)
            }
        }
    }

    public func addToolToWorkspace(workspaceID: UUID, tool: ToolReference) async throws {
        try workspacesState.withLock {
            guard let index = $0.firstIndex(where: { $0.id == workspaceID }) else {
                throw ToolError.workspaceNotFound(workspaceID)
            }

            var workspace = $0[index]
            workspace.tools.append(tool)
            $0[index] = workspace
        }
    }

    public func syncTools(workspaceID: UUID, tools: [ToolReference]) async throws {
        try workspacesState.withLock {
            guard let index = $0.firstIndex(where: { $0.id == workspaceID }) else {
                throw ToolError.workspaceNotFound(workspaceID)
            }

            var workspace = $0[index]
            workspace.tools = tools
            $0[index] = workspace
        }
    }

    public func fetchTools(forWorkspaces workspaceIDs: [UUID]) async throws -> [ToolReference] {
        workspacesState.withLock {
            $0.filter { workspaceIDs.contains($0.id) }.flatMap(\.tools)
        }
    }

    public func fetchOriginTools(originID: UUID) async throws -> [ToolReference] {
        workspacesState.withLock {
            $0.filter { $0.originID == originID }.flatMap(\.tools)
        }
    }

    public func findWorkspaceID(forToolID toolID: String, in workspaceIDs: [UUID]) async throws -> UUID? {
        workspacesState.withLock {
            for workspace in $0 where workspaceIDs.contains(workspace.id) {
                if workspace.tools.contains(where: { $0.toolID == toolID }) {
                    return workspace.id
                }
            }
            return nil
        }
    }

    public func fetchToolSource(toolID: String, workspaceIDs: [UUID], primaryWorkspaceID: UUID?) async throws -> String? {
        workspacesState.withLock {
            guard let workspace = $0.first(where: { workspace in
                workspaceIDs.contains(workspace.id)
                    && workspace.tools.contains { $0.toolID == toolID }
            }) else {
                return nil
            }

            if workspace.location == .attached {
                return "Additional Workspace"
            } else if workspace.id == primaryWorkspaceID {
                return "Primary Workspace"
            } else {
                return "Workspace: \(workspace.uri.description)"
            }
        }
    }
}
