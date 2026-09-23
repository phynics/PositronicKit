import Foundation

/// The in-memory Workspace binding bookkeeping shared by ``InMemoryWorkspaceBindingRepository``,
/// ``InMemoryWorkspacePersistence``, and ``InMemoryTimelineRuntimeRepository``.
///
/// A value type so each owning actor keeps its own serialization boundary; the actor makes every
/// mutation atomic, and this table keeps the two indexes consistent.
struct WorkspaceBindingTable {
    private var byWorkspace: [UUID: WorkspaceBinding] = [:]
    private var byTimeline: [UUID: Set<UUID>] = [:]

    mutating func claim(workspaceID: UUID, for timelineID: UUID, now: Date) throws -> WorkspaceBinding {
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
        insert(binding)
        return binding
    }

    mutating func release(workspaceID: UUID, from timelineID: UUID) throws {
        guard let existing = byWorkspace[workspaceID], existing.timelineID == timelineID else {
            throw WorkspaceBindingRepositoryError.bindingNotFound(
                workspaceID: workspaceID,
                timelineID: timelineID
            )
        }
        remove(existing)
    }

    mutating func transfer(
        workspaceID: UUID,
        from sourceTimelineID: UUID,
        to destinationTimelineID: UUID,
        now: Date
    ) throws -> WorkspaceBinding {
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
        remove(existing)
        insert(binding)
        return binding
    }

    /// Drops the binding of `workspaceID`, if any, as when the Workspace itself is deleted.
    mutating func removeBinding(of workspaceID: UUID) {
        if let existing = byWorkspace[workspaceID] {
            remove(existing)
        }
    }

    /// Drops every binding held by `timelineID`, as when the Timeline itself is deleted.
    mutating func removeAll(for timelineID: UUID) {
        for workspaceID in byTimeline.removeValue(forKey: timelineID) ?? [] {
            byWorkspace.removeValue(forKey: workspaceID)
        }
    }

    func bindings(for timelineID: UUID) -> [WorkspaceBinding] {
        (byTimeline[timelineID] ?? [])
            .compactMap { byWorkspace[$0] }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func timelineID(for workspaceID: UUID) -> UUID? {
        byWorkspace[workspaceID]?.timelineID
    }

    private mutating func insert(_ binding: WorkspaceBinding) {
        byWorkspace[binding.workspaceID] = binding
        byTimeline[binding.timelineID, default: []].insert(binding.workspaceID)
    }

    private mutating func remove(_ binding: WorkspaceBinding) {
        byWorkspace.removeValue(forKey: binding.workspaceID)
        byTimeline[binding.timelineID]?.remove(binding.workspaceID)
        if byTimeline[binding.timelineID]?.isEmpty == true {
            byTimeline.removeValue(forKey: binding.timelineID)
        }
    }
}
