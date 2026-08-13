import ErrorKit
import Foundation
import Logging
import PKShared
import PKUtilities

// MARK: - Workspace Attachment

public extension TimelineManager {
    func attachWorkspace(_ workspaceId: UUID, to timelineId: UUID) async throws {
        let livenessVersion = timelineLivenessVersion(for: timelineId)
        try requireTimelineLiveness(for: timelineId, version: livenessVersion)
        var timeline: Timeline

        if let memoryTimeline = timelines[timelineId] {
            timeline = memoryTimeline
        } else {
            do {
                guard let dbTimeline = try await timelineStore.fetchTimeline(id: timelineId) else {
                    throw TimelineError.timelineNotFound
                }
                timeline = dbTimeline
                try requireTimelineLiveness(for: timelineId, version: livenessVersion)
            } catch let error as TimelineError {
                throw error
            } catch {
                logger.error("""
                attachWorkspace fetch failed — timeline: \(timelineId.uuidString.prefix(8)), \
                operation: fetchTimeline, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                throw TimelineError.unavailable
            }
        }

        do {
            guard try await workspaceStore.fetchWorkspace(
                id: workspaceId, includeTools: false
            ) != nil else {
                logger.warning("""
                attachWorkspace: workspace not found — \
                workspace: \(workspaceId.uuidString.prefix(8)), \
                timeline: \(timelineId.uuidString.prefix(8)), operation: validateWorkspace
                """)
                throw TimelineError.invalidState("workspace \(workspaceId.uuidString.prefix(8)) not found")
            }
        } catch let error as TimelineError {
            throw error
        } catch {
            logger.error("""
            attachWorkspace: workspace validation failed — \
            workspace: \(workspaceId.uuidString.prefix(8)), \
            timeline: \(timelineId.uuidString.prefix(8)), \
            operation: validateWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            throw TimelineError.unavailable
        }

        try requireTimelineLiveness(for: timelineId, version: livenessVersion)

        if !timeline.attachedWorkspaceIDs.contains(workspaceId) {
            timeline.attachedWorkspaceIDs.append(workspaceId)
        }
        timeline.updatedAt = Date()

        try await timelineStore.saveTimeline(timeline)
        do {
            try requireTimelineLiveness(for: timelineId, version: livenessVersion)
        } catch {
            // A deletion may have interleaved with the save itself. Remove a stale upsert so the
            // deleted timeline cannot be resurrected even when persistence operations reorder.
            try? await timelineStore.deleteTimeline(id: timelineId)
            throw error
        }
        if timelines[timeline.id] != nil { timelines[timeline.id] = timeline }

        if let toolManager = toolManagers[timelineId] {
            do {
                if let resolved = try await workspaceResolver.workspace(id: workspaceId) {
                    await toolManager.registerWorkspace(resolved)
                }
            } catch {
                logger.warning("""
                attachWorkspace: workspace registration failed — \
                workspace: \(workspaceId.uuidString.prefix(8)), timeline: \(timelineId.uuidString.prefix(8)), \
                operation: registerWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                timelineDegradations[timelineId, default: []].append(TurnDiagnostic(
                    dependency: .workspace,
                    operation: "registerWorkspace",
                    entityID: "workspace:\(workspaceId.uuidString.prefix(8))",
                    errorIdentity: ChatEvent.ErrorIdentity.extracting(from: error),
                    message: ErrorKit.userFriendlyMessage(for: error)
                ))
            }
        }
    }

    func detachWorkspace(_ workspaceId: UUID, from timelineId: UUID) async throws {
        var timeline: Timeline

        if let memoryTimeline = timelines[timelineId] {
            timeline = memoryTimeline
        } else {
            do {
                guard let dbTimeline = try await timelineStore.fetchTimeline(id: timelineId) else {
                    throw TimelineError.timelineNotFound
                }
                timeline = dbTimeline
            } catch let error as TimelineError {
                throw error
            } catch {
                logger.error("""
                detachWorkspace fetch failed — timeline: \(timelineId.uuidString.prefix(8)), \
                operation: fetchTimeline, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                throw TimelineError.unavailable
            }
        }

        timeline.attachedWorkspaceIDs.removeAll { $0 == workspaceId }
        timeline.updatedAt = Date()

        try await timelineStore.saveTimeline(timeline)
        if timelines[timeline.id] != nil { timelines[timeline.id] = timeline }

        if let toolManager = toolManagers[timelineId] {
            await toolManager.unregisterWorkspace(workspaceId)
        }
    }

    // MARK: - Workspace Lookup

    func getWorkspaces(for timelineId: UUID) async throws -> WorkspaceQueryResult {
        let attachedIds: [UUID]

        if let timeline = timelines[timelineId] {
            attachedIds = timeline.attachedWorkspaceIDs
        } else {
            do {
                guard let timeline = try await timelineStore.fetchTimeline(id: timelineId) else {
                    throw TimelineError.timelineNotFound
                }
                attachedIds = timeline.attachedWorkspaceIDs
            } catch let error as TimelineError {
                throw error
            } catch {
                logger.error("""
                getWorkspaces fetch failed — timeline: \(timelineId.uuidString.prefix(8)), \
                operation: fetchTimeline, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                throw TimelineError.unavailable
            }
        }

        var primary: WorkspaceReference?
        var attached: [WorkspaceReference] = []
        var degradations: [StoreDegradation] = []
        for aid in attachedIds {
            do {
                if let workspace = try await getWorkspace(aid) {
                    let normalizedWorkspace = normalizeWorkspaceStatus(workspace)

                    if primary == nil,
                       normalizedWorkspace.location == .runtime
                        || normalizedWorkspace.location == .runtimeThread
                        || normalizedWorkspace.location == .runtimeTimeline
                    {
                        primary = normalizedWorkspace
                    } else {
                        attached.append(normalizedWorkspace)
                    }
                }
            } catch {
                let degradation = StoreDegradation(
                    operation: "getWorkspaces.fetchWorkspace",
                    entityID: "workspace:\(aid.uuidString.prefix(8))",
                    error: error
                )
                degradations.append(degradation)
                logger.warning("""
                getWorkspaces: individual workspace fetch failed — \
                workspace: \(aid.uuidString.prefix(8)), timeline: \(timelineId.uuidString.prefix(8)), \
                operation: fetchWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
            }
        }

        return WorkspaceQueryResult(primary: primary, attached: attached, degradations: degradations)
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
