import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

// MARK: - Workspace Attachment

extension TimelineManager {
    func attachWorkspace(_ workspaceId: UUID, to timelineID: UUID) async throws {
        try await requireExecutionContextMutable(for: timelineID)
        let livenessVersion = timelineLivenessVersion(for: timelineID)
        try requireTimelineLiveness(for: timelineID, version: livenessVersion)
        _ = try await cachedOrStoredTimeline(timelineID, operation: "attachWorkspace")
        try requireTimelineLiveness(for: timelineID, version: livenessVersion)

        do {
            guard try await workspaceStore.fetchWorkspace(
                id: workspaceId, includeTools: false
            ) != nil else {
                logger.warning("""
                attachWorkspace: workspace not found — \
                workspace: \(workspaceId.uuidString.prefix(8)), \
                timeline: \(timelineID.uuidString.prefix(8)), operation: validateWorkspace
                """)
                throw TimelineError.invalidState("workspace \(workspaceId.uuidString.prefix(8)) not found")
            }
        } catch let error as TimelineError {
            throw error
        } catch {
            logger.error("""
            attachWorkspace: workspace validation failed — \
            workspace: \(workspaceId.uuidString.prefix(8)), \
            timeline: \(timelineID.uuidString.prefix(8)), \
            operation: validateWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            throw TimelineError.unavailable
        }

        try requireTimelineLiveness(for: timelineID, version: livenessVersion)

        let (timeline, claimedNewBinding): (TimelineRecord, Bool) = try await withTimelineAuthority(timelineID) { [self] in
            // The initial lookup above only validates the request. Re-read after acquiring the
            // authority lane so metadata committed by another Timeline mutation is not overwritten.
            var candidate = try await self.storedTimeline(timelineID, operation: "attachWorkspace refresh")
            try await self.requireTimelineLiveness(for: timelineID, version: livenessVersion)
            let existingOwner = try await self.workspaceBindingRepository.timelineID(for: workspaceId)
            if let existingOwner, existingOwner != timelineID {
                throw WorkspaceBindingRepositoryError.workspaceAlreadyBound(
                    workspaceID: workspaceId,
                    timelineID: existingOwner
                )
            }
            try await self.requireExecutionContextMutable(for: timelineID)
            let claimed = existingOwner == nil
            if claimed {
                _ = try await self.workspaceBindingRepository.claim(
                    workspaceID: workspaceId,
                    for: timelineID,
                    now: Date()
                )
            }
            do {
                try await self.requireExecutionContextMutable(for: timelineID)
                candidate.updatedAt = Date()
                try await self.timelineStore.saveTimeline(candidate)
            } catch {
                if claimed {
                    _ = try? await self.workspaceBindingRepository.release(
                        workspaceID: workspaceId,
                        from: timelineID,
                        now: Date()
                    )
                }
                throw error
            }
            return (candidate, claimed)
        }
        do {
            try requireTimelineLiveness(for: timelineID, version: livenessVersion)
        } catch {
            // A deletion may have interleaved with the save itself. Remove a stale upsert so the
            // deleted timeline cannot be resurrected even when persistence operations reorder.
            try? await self.timelineStore.deleteTimeline(id: timelineID)
            if claimedNewBinding {
                _ = try? await self.workspaceBindingRepository.release(
                    workspaceID: workspaceId,
                    from: timelineID,
                    now: Date()
                )
            }
            throw error
        }
        replaceCachedTimelineIfPresent(timeline)

        if let toolManager = toolManagers[timelineID] {
            do {
                if let resolved = try await workspaceResolver.workspace(id: workspaceId) {
                    await toolManager.registerWorkspace(resolved)
                }
            } catch {
                logger.warning("""
                attachWorkspace: workspace registration failed — \
                workspace: \(workspaceId.uuidString.prefix(8)), timeline: \(timelineID.uuidString.prefix(8)), \
                operation: registerWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                timelineDegradations[timelineID, default: []].append(TurnDiagnostic(
                    dependency: .workspace,
                    operation: "registerWorkspace",
                    entityID: "workspace:\(workspaceId.uuidString.prefix(8))",
                    error: error
                ))
            }
        }
    }

    func detachWorkspace(_ workspaceId: UUID, from timelineID: UUID) async throws {
        try await requireExecutionContextMutable(for: timelineID)
        _ = try await cachedOrStoredTimeline(timelineID, operation: "detachWorkspace")

        let timeline = try await withTimelineAuthority(timelineID) { [self] in
            // The initial lookup above only validates the request. Re-read after acquiring the
            // authority lane so metadata committed by another Timeline mutation is not overwritten.
            var candidate = try await self.storedTimeline(timelineID, operation: "detachWorkspace refresh")
            let owner = try await self.workspaceBindingRepository.timelineID(for: workspaceId)
            try await self.requireExecutionContextMutable(for: timelineID)
            if owner == timelineID {
                try await self.workspaceBindingRepository.release(
                    workspaceID: workspaceId,
                    from: timelineID,
                    now: Date()
                )
            } else if let owner {
                throw WorkspaceBindingRepositoryError.workspaceAlreadyBound(
                    workspaceID: workspaceId,
                    timelineID: owner
                )
            }
            do {
                try await self.requireExecutionContextMutable(for: timelineID)
                candidate.updatedAt = Date()
                try await self.timelineStore.saveTimeline(candidate)
            } catch {
                if owner == timelineID {
                    _ = try? await self.workspaceBindingRepository.claim(
                        workspaceID: workspaceId,
                        for: timelineID,
                        now: Date()
                    )
                }
                throw error
            }
            return candidate
        }
        replaceCachedTimelineIfPresent(timeline)

        if let toolManager = toolManagers[timelineID] {
            await toolManager.unregisterWorkspace(workspaceId)
        }
    }

    // MARK: - Workspace Lookup

    func getWorkspaces(for timelineID: UUID) async throws -> WorkspaceQueryResult {
        _ = try await cachedOrStoredTimeline(timelineID, operation: "getWorkspaces")

        let attachedIds: [UUID]
        do {
            attachedIds = try await workspaceBindingRepository
                .bindings(for: timelineID)
                .map(\.workspaceID)
        } catch {
            logger.error("""
            getWorkspaces binding lookup failed — timeline: \(timelineID.uuidString.prefix(8)), \
            operation: fetchWorkspaceBindings, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            throw TimelineError.unavailable
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
                workspace: \(aid.uuidString.prefix(8)), timeline: \(timelineID.uuidString.prefix(8)), \
                operation: fetchWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
            }
        }

        return WorkspaceQueryResult(primary: primary, attached: attached, degradations: degradations)
    }

    private func getWorkspace(_ id: UUID) async throws -> WorkspaceReference? {
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
