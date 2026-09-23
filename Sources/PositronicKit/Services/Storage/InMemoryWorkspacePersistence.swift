import Foundation
import PKContracts
import PKUtilities

/// Timeline-safe in-memory workspace persistence for prototyping and development.
public actor InMemoryWorkspacePersistence: WorkspaceStore, WorkspaceBindingRepository {
    private var workspaces: [WorkspaceReference] = []
    private var workspaceBindings = WorkspaceBindingTable()

    public init() {}

    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    public func fetchWorkspace(id: UUID, includeTools _: Bool = false) async throws -> WorkspaceReference? {
        workspaces.first { $0.id == id }
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        workspaces
    }

    public func deleteWorkspace(id: UUID) async throws {
        workspaces.removeAll { $0.id == id }
        workspaceBindings.removeBinding(of: id)
    }

    package func replaceWorkspaces(_ workspaces: [WorkspaceReference]) {
        self.workspaces = workspaces
    }

    // MARK: WorkspaceBindingRepository

    public func claim(
        workspaceID: UUID,
        for timelineID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        try workspaceBindings.claim(workspaceID: workspaceID, for: timelineID, now: now)
    }

    public func release(
        workspaceID: UUID,
        from timelineID: UUID,
        now _: Date = Date()
    ) async throws {
        try workspaceBindings.release(workspaceID: workspaceID, from: timelineID)
    }

    public func transfer(
        workspaceID: UUID,
        from sourceTimelineID: UUID,
        to destinationTimelineID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        try workspaceBindings.transfer(
            workspaceID: workspaceID,
            from: sourceTimelineID,
            to: destinationTimelineID,
            now: now
        )
    }

    public func bindings(for timelineID: UUID) async throws -> [WorkspaceBinding] {
        workspaceBindings.bindings(for: timelineID)
    }

    public func timelineID(for workspaceID: UUID) async throws -> UUID? {
        workspaceBindings.timelineID(for: workspaceID)
    }
}
