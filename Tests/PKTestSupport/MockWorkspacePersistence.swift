import Foundation
import PositronicKit
import PKShared

public final class MockWorkspacePersistence: WorkspacePersistenceProtocol, @unchecked Sendable {
    private let backing = InMemoryWorkspacePersistence()

    public var workspaces: [WorkspaceReference] {
        get { (try? BlockingAsync.run { [self] in await self.backing.allWorkspaces() }) ?? [] }
        set { _ = try? BlockingAsync.run { [self] in await self.backing.replaceWorkspaces(newValue) } }
    }

    public init() {}

    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        try await backing.saveWorkspace(workspace)
    }

    public func fetchWorkspace(id: UUID, includeTools _: Bool = false) async throws -> WorkspaceReference? {
        try await backing.fetchWorkspace(id: id)
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        try await backing.fetchAllWorkspaces()
    }

    public func deleteWorkspace(id: UUID) async throws {
        try await backing.deleteWorkspace(id: id)
    }
}
