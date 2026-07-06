import Foundation
import PKShared

/// Manages workspace attachment, detachment, and lookup for a timeline.
///
/// Extracted from `TimelineManager` (PKARCH-003) so callers that only want to attach or detach a
/// workspace can reason about a focused module rather than the full timeline coordinator. Reads
/// and mutates the shared in-memory caches through the narrow ``TimelineCache`` seam, which stays
/// owned by `TimelineManager`.
package struct WorkspaceAttachmentService: Sendable {
    package let cache: any TimelineCache
    package let timelineStore: any TimelinePersistenceProtocol
    package let workspaceStore: any WorkspacePersistenceProtocol
    package let workspaceManager: any WorkspaceManagerProtocol

    package init(
        cache: any TimelineCache,
        timelineStore: any TimelinePersistenceProtocol,
        workspaceStore: any WorkspacePersistenceProtocol,
        workspaceManager: any WorkspaceManagerProtocol
    ) {
        self.cache = cache
        self.timelineStore = timelineStore
        self.workspaceStore = workspaceStore
        self.workspaceManager = workspaceManager
    }

    // MARK: - Attach / Detach

    package func attachWorkspace(_ workspaceId: UUID, to timelineId: UUID) async throws {
        var timeline: Timeline

        if let memoryTimeline = await cache.cacheReadTimeline(id: timelineId) {
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

        await cache.cacheReplaceTimelineIfPresent(timeline)
        try await timelineStore.saveTimeline(timeline)

        if let toolManager = await cache.cacheReadToolManager(for: timelineId) {
            if let workspace = try? await workspaceManager.getWorkspace(id: workspaceId) {
                await toolManager.registerWorkspace(workspace)
            }
        }
    }

    package func detachWorkspace(_ workspaceId: UUID, from timelineId: UUID) async throws {
        var timeline: Timeline

        if let memoryTimeline = await cache.cacheReadTimeline(id: timelineId) {
            timeline = memoryTimeline
        } else if let dbTimeline = try? await timelineStore.fetchTimeline(id: timelineId) {
            timeline = dbTimeline
        } else {
            throw TimelineError.timelineNotFound
        }

        timeline.attachedWorkspaceIds.removeAll { $0 == workspaceId }
        timeline.updatedAt = Date()

        await cache.cacheReplaceTimelineIfPresent(timeline)
        try await timelineStore.saveTimeline(timeline)

        if let toolManager = await cache.cacheReadToolManager(for: timelineId) {
            await toolManager.unregisterWorkspace(workspaceId)
        }
    }

    // MARK: - Lookup

    package func getWorkspaces(for timelineId: UUID) async -> (primary: WorkspaceReference?, attached: [WorkspaceReference])? {
        let attachedIds: [UUID]

        if let timeline = await cache.cacheReadTimeline(id: timelineId) {
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

    package func getWorkspace(_ id: UUID) async throws -> WorkspaceReference? {
        try await workspaceStore.fetchWorkspace(id: id, includeTools: true)
    }

    /// Returns `.missing` for a `.runtime` workspace whose `rootPath` no longer exists on disk;
    /// leaves other workspaces (including `.attached` and `.runtimeTimeline`) unchanged. Mirrors
    /// the inline normalization in the original `TimelineManager.getWorkspaces(for:)`.
    private func normalizeWorkspaceStatus(_ workspace: WorkspaceReference) -> WorkspaceReference {
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