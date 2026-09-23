import Foundation

/// Actor-backed Workspace binding repository for local hosts and tests.
///
/// The actor models the atomic conditional claim that a durable adapter must provide. It does
/// not infer Agent ownership: callers only claim ordinary Timeline bindings here.
public actor InMemoryWorkspaceBindingRepository: WorkspaceBindingRepository {
    private var workspaceBindings = WorkspaceBindingTable()

    public init() {}

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
