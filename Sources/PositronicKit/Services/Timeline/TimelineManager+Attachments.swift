import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

// MARK: - Workspace Attachment

public extension ThreadManager {
    func attachWorkspace(_ workspaceId: UUID, to threadID: UUID) async throws {
        let livenessVersion = threadLivenessVersion(for: threadID)
        try requireThreadLiveness(for: threadID, version: livenessVersion)
        var timeline: Thread

        if let memoryTimeline = timelines[threadID] {
            timeline = memoryTimeline
        } else {
            do {
                guard let dbTimeline = try await threadStore.fetchThread(id: threadID) else {
                    throw ThreadError.threadNotFound
                }
                timeline = dbTimeline
                try requireThreadLiveness(for: threadID, version: livenessVersion)
            } catch let error as ThreadError {
                throw error
            } catch {
                logger.error("""
                attachWorkspace fetch failed — thread: \(threadID.uuidString.prefix(8)), \
                operation: fetchTimeline, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                throw ThreadError.unavailable
            }
        }

        do {
            guard try await workspaceStore.fetchWorkspace(
                id: workspaceId, includeTools: false
            ) != nil else {
                logger.warning("""
                attachWorkspace: workspace not found — \
                workspace: \(workspaceId.uuidString.prefix(8)), \
                thread: \(threadID.uuidString.prefix(8)), operation: validateWorkspace
                """)
                throw ThreadError.invalidState("workspace \(workspaceId.uuidString.prefix(8)) not found")
            }
        } catch let error as ThreadError {
            throw error
        } catch {
            logger.error("""
            attachWorkspace: workspace validation failed — \
            workspace: \(workspaceId.uuidString.prefix(8)), \
            thread: \(threadID.uuidString.prefix(8)), \
            operation: validateWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            throw ThreadError.unavailable
        }

        try requireThreadLiveness(for: threadID, version: livenessVersion)

        if !timeline.attachedWorkspaceIDs.contains(workspaceId) {
            timeline.attachedWorkspaceIDs.append(workspaceId)
        }
        timeline.updatedAt = Date()

        try await threadStore.saveThread(timeline)
        do {
            try requireThreadLiveness(for: threadID, version: livenessVersion)
        } catch {
            // A deletion may have interleaved with the save itself. Remove a stale upsert so the
            // deleted thread cannot be resurrected even when persistence operations reorder.
            try? await threadStore.deleteThread(id: threadID)
            throw error
        }
        if timelines[timeline.id] != nil { timelines[timeline.id] = timeline }

        if let toolManager = toolManagers[threadID] {
            do {
                if let resolved = try await workspaceResolver.workspace(id: workspaceId) {
                    await toolManager.registerWorkspace(resolved)
                }
            } catch {
                logger.warning("""
                attachWorkspace: workspace registration failed — \
                workspace: \(workspaceId.uuidString.prefix(8)), thread: \(threadID.uuidString.prefix(8)), \
                operation: registerWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                timelineDegradations[threadID, default: []].append(TurnDiagnostic(
                    dependency: .workspace,
                    operation: "registerWorkspace",
                    entityID: "workspace:\(workspaceId.uuidString.prefix(8))",
                    errorIdentity: ChatEvent.ErrorIdentity.extracting(from: error),
                    message: ErrorKit.userFriendlyMessage(for: error)
                ))
            }
        }
    }

    func detachWorkspace(_ workspaceId: UUID, from threadID: UUID) async throws {
        var timeline: Thread

        if let memoryTimeline = timelines[threadID] {
            timeline = memoryTimeline
        } else {
            do {
                guard let dbTimeline = try await threadStore.fetchThread(id: threadID) else {
                    throw ThreadError.threadNotFound
                }
                timeline = dbTimeline
            } catch let error as ThreadError {
                throw error
            } catch {
                logger.error("""
                detachWorkspace fetch failed — thread: \(threadID.uuidString.prefix(8)), \
                operation: fetchTimeline, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                throw ThreadError.unavailable
            }
        }

        timeline.attachedWorkspaceIDs.removeAll { $0 == workspaceId }
        timeline.updatedAt = Date()

        try await threadStore.saveThread(timeline)
        if timelines[timeline.id] != nil { timelines[timeline.id] = timeline }

        if let toolManager = toolManagers[threadID] {
            await toolManager.unregisterWorkspace(workspaceId)
        }
    }

    // MARK: - Workspace Lookup

    func getWorkspaces(for threadID: UUID) async throws -> WorkspaceQueryResult {
        let attachedIds: [UUID]

        if let timeline = timelines[threadID] {
            attachedIds = timeline.attachedWorkspaceIDs
        } else {
            do {
                guard let timeline = try await threadStore.fetchThread(id: threadID) else {
                    throw ThreadError.threadNotFound
                }
                attachedIds = timeline.attachedWorkspaceIDs
            } catch let error as ThreadError {
                throw error
            } catch {
                logger.error("""
                getWorkspaces fetch failed — thread: \(threadID.uuidString.prefix(8)), \
                operation: fetchTimeline, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                throw ThreadError.unavailable
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
                workspace: \(aid.uuidString.prefix(8)), thread: \(threadID.uuidString.prefix(8)), \
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

private extension ThreadManager {
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
