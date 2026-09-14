import Foundation

/// Actor-backed Workspace binding repository for local hosts and tests.
///
/// The actor models the atomic conditional claim that a durable adapter must provide. It does
/// not infer Agent ownership: callers only claim ordinary Timeline bindings here.
public actor InMemoryWorkspaceBindingRepository: WorkspaceBindingRepository {
    private var byWorkspace: [UUID: WorkspaceBinding] = [:]
    private var byTimeline: [UUID: Set<UUID>] = [:]

    public init() {}

    public func claim(
        workspaceID: UUID,
        for timelineID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        if let existing = byWorkspace[workspaceID] {
            guard existing.timelineID == timelineID else {
                throw WorkspaceBindingRepositoryError.workspaceAlreadyBound(
                    workspaceID: workspaceID,
                    timelineID: existing.timelineID
                )
            }
            return existing
        }

        let binding = WorkspaceBinding(
            workspaceID: workspaceID,
            timelineID: timelineID,
            createdAt: now,
            updatedAt: now
        )
        byWorkspace[workspaceID] = binding
        byTimeline[timelineID, default: []].insert(workspaceID)
        return binding
    }

    public func release(
        workspaceID: UUID,
        from timelineID: UUID,
        now _: Date = Date()
    ) async throws {
        guard let existing = byWorkspace[workspaceID], existing.timelineID == timelineID else {
            throw WorkspaceBindingRepositoryError.bindingNotFound(
                workspaceID: workspaceID,
                timelineID: timelineID
            )
        }
        byWorkspace.removeValue(forKey: workspaceID)
        byTimeline[timelineID]?.remove(workspaceID)
        if byTimeline[timelineID]?.isEmpty == true {
            byTimeline.removeValue(forKey: timelineID)
        }
    }

    public func transfer(
        workspaceID: UUID,
        from sourceTimelineID: UUID,
        to destinationTimelineID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        guard let existing = byWorkspace[workspaceID], existing.timelineID == sourceTimelineID else {
            throw WorkspaceBindingRepositoryError.transferSourceMismatch(
                workspaceID: workspaceID,
                timelineID: sourceTimelineID
            )
        }
        let binding = WorkspaceBinding(
            workspaceID: workspaceID,
            timelineID: destinationTimelineID,
            createdAt: existing.createdAt,
            updatedAt: now
        )
        byWorkspace[workspaceID] = binding
        byTimeline[sourceTimelineID]?.remove(workspaceID)
        if byTimeline[sourceTimelineID]?.isEmpty == true {
            byTimeline.removeValue(forKey: sourceTimelineID)
        }
        byTimeline[destinationTimelineID, default: []].insert(workspaceID)
        return binding
    }

    public func bindings(for timelineID: UUID) async throws -> [WorkspaceBinding] {
        (byTimeline[timelineID] ?? [])
            .compactMap { byWorkspace[$0] }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func timelineID(for workspaceID: UUID) async throws -> UUID? {
        byWorkspace[workspaceID]?.timelineID
    }
}
