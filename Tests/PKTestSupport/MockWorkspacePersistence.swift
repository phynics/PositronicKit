import Foundation
import PKContracts
import PKUtilities
import PositronicKit
import Synchronization

/// In-memory `WorkspaceStore` test double backed by a mutex-guarded array.
///
/// Inspectable: `workspaces` reads/writes the backing store directly, so tests can seed
/// fixtures or assert on saved state. `fetchWorkspace` ignores `includeTools` (tools are
/// always present as stored, unlike the split real-persistence path).
public final class MockWorkspacePersistence: WorkspaceStore, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    private let workspacesState = Mutex<[WorkspaceReference]>([])

    public var workspaces: [WorkspaceReference] {
        get { workspacesState.withLock { $0 } }
        set { workspacesState.withLock { $0 = newValue } }
    }

    public init() {}

    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        workspacesState.withLock {
            if let index = $0.firstIndex(where: { $0.id == workspace.id }) {
                $0[index] = workspace
            } else {
                $0.append(workspace)
            }
        }
    }

    public func fetchWorkspace(id: UUID, includeTools _: Bool = false) async throws -> WorkspaceReference? {
        workspacesState.withLock {
            $0.first { $0.id == id }
        }
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        workspacesState.withLock { $0 }
    }

    public func deleteWorkspace(id: UUID) async throws {
        workspacesState.withLock {
            $0.removeAll { $0.id == id }
        }
    }
}
