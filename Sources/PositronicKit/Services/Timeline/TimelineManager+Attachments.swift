import Foundation
import PKShared
import PKUtilities

// MARK: - Workspace Attachment

public extension TimelineManager {
    func attachWorkspace(_ workspaceId: UUID, to timelineId: UUID) async throws {
        var timeline: Timeline

        if let memoryTimeline = timelines[timelineId] {
            timeline = memoryTimeline
        } else if let dbTimeline = try? await timelineStore.fetchTimeline(id: timelineId) {
            timeline = dbTimeline
        } else {
            throw TimelineError.timelineNotFound
        }

        if !timeline.attachedWorkspaceIds.contains(workspaceId) {
            timeline.attachedWorkspaceIds.append(workspaceId)
        }

        timeline.updatedAt = Date()

        if timelines[timeline.id] != nil { timelines[timeline.id] = timeline }
        try await timelineStore.saveTimeline(timeline)

        if let toolManager = toolManagers[timelineId] {
            if let workspace = try? await workspaceResolver.getWorkspace(id: workspaceId) {
                await toolManager.registerWorkspace(workspace)
            }
        }
    }

    func detachWorkspace(_ workspaceId: UUID, from timelineId: UUID) async throws {
        var timeline: Timeline

        if let memoryTimeline = timelines[timelineId] {
            timeline = memoryTimeline
        } else if let dbTimeline = try? await timelineStore.fetchTimeline(id: timelineId) {
            timeline = dbTimeline
        } else {
            throw TimelineError.timelineNotFound
        }

        timeline.attachedWorkspaceIds.removeAll { $0 == workspaceId }
        timeline.updatedAt = Date()

        if timelines[timeline.id] != nil { timelines[timeline.id] = timeline }
        try await timelineStore.saveTimeline(timeline)

        if let toolManager = toolManagers[timelineId] {
            await toolManager.unregisterWorkspace(workspaceId)
        }
    }

    // MARK: - Workspace Lookup

    func getWorkspaces(for timelineId: UUID) async -> (primary: WorkspaceReference?, attached: [WorkspaceReference])? {
        let attachedIds: [UUID]

        if let timeline = timelines[timelineId] {
            attachedIds = timeline.attachedWorkspaceIds
        } else if let timeline = try? await timelineStore.fetchTimeline(id: timelineId) {
            attachedIds = timeline.attachedWorkspaceIds
        } else {
            return nil
        }

        var primary: WorkspaceReference?
        var attached: [WorkspaceReference] = []
        for aid in attachedIds {
            if let workspace = try? await getWorkspace(aid) {
                let normalizedWorkspace = normalizeWorkspaceStatus(workspace)

                if primary == nil,
                   normalizedWorkspace.location == .runtime || normalizedWorkspace.location == .runtimeTimeline
                {
                    primary = normalizedWorkspace
                } else {
                    attached.append(normalizedWorkspace)
                }
            }
        }

        return (primary, attached)
    }

    func getWorkspace(_ id: UUID) async throws -> WorkspaceReference? {
        try await workspaceStore.fetchWorkspace(id: id, includeTools: true)
    }
}

// MARK: - Workspace Status Normalization

private extension TimelineManager {
    /// Returns `.missing` for a `.runtime` workspace whose `rootPath` no longer exists on disk;
    /// leaves other workspaces (including `.attached` and `.runtimeTimeline`) unchanged.
    func normalizeWorkspaceStatus(_ workspace: WorkspaceReference) -> WorkspaceReference {
        var normalizedWorkspace = workspace
        if normalizedWorkspace.location == .runtime,
           let path = normalizedWorkspace.rootPath,
           !FileManager.default.fileExists(atPath: path)
        {
            normalizedWorkspace.status = .missing
        }
        return normalizedWorkspace
    }
}
