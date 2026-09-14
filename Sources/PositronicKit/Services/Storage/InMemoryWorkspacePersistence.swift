import Foundation
import PKContracts
import PKUtilities

/// Timeline-safe in-memory workspace persistence for prototyping and development.
public actor InMemoryWorkspacePersistence: WorkspaceStore, WorkspaceBindingRepository {
    private var workspaces: [WorkspaceReference] = []
    private var bindingsByWorkspace: [UUID: WorkspaceBinding] = [:]
    private var workspaceIDsByTimeline: [UUID: Set<UUID>] = [:]

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
        if let binding = bindingsByWorkspace.removeValue(forKey: id) {
            workspaceIDsByTimeline[binding.timelineID]?.remove(id)
            if workspaceIDsByTimeline[binding.timelineID]?.isEmpty == true {
                workspaceIDsByTimeline.removeValue(forKey: binding.timelineID)
            }
        }
    }

    package func allWorkspaces() -> [WorkspaceReference] {
        workspaces
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
        if let existing = bindingsByWorkspace[workspaceID] {
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
        bindingsByWorkspace[workspaceID] = binding
        workspaceIDsByTimeline[timelineID, default: []].insert(workspaceID)
        return binding
    }

    public func release(
        workspaceID: UUID,
        from timelineID: UUID,
        now _: Date = Date()
    ) async throws {
        guard let existing = bindingsByWorkspace[workspaceID], existing.timelineID == timelineID else {
            throw WorkspaceBindingRepositoryError.bindingNotFound(
                workspaceID: workspaceID,
                timelineID: timelineID
            )
        }
        bindingsByWorkspace.removeValue(forKey: workspaceID)
        workspaceIDsByTimeline[timelineID]?.remove(workspaceID)
        if workspaceIDsByTimeline[timelineID]?.isEmpty == true {
            workspaceIDsByTimeline.removeValue(forKey: timelineID)
        }
    }

    public func transfer(
        workspaceID: UUID,
        from sourceTimelineID: UUID,
        to destinationTimelineID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        guard let existing = bindingsByWorkspace[workspaceID], existing.timelineID == sourceTimelineID else {
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
        bindingsByWorkspace[workspaceID] = binding
        workspaceIDsByTimeline[sourceTimelineID]?.remove(workspaceID)
        if workspaceIDsByTimeline[sourceTimelineID]?.isEmpty == true {
            workspaceIDsByTimeline.removeValue(forKey: sourceTimelineID)
        }
        workspaceIDsByTimeline[destinationTimelineID, default: []].insert(workspaceID)
        return binding
    }

    public func bindings(for timelineID: UUID) async throws -> [WorkspaceBinding] {
        (workspaceIDsByTimeline[timelineID] ?? [])
            .compactMap { bindingsByWorkspace[$0] }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func timelineID(for workspaceID: UUID) async throws -> UUID? {
        bindingsByWorkspace[workspaceID]?.timelineID
    }
}
