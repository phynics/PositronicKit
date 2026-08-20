import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

// MARK: - Workspace Attachment

public extension ThreadManager {
    func attachWorkspace(_ workspaceId: UUID, to threadID: UUID) async throws {
        try await requireExecutionContextMutable(for: threadID)
        let livenessVersion = threadLivenessVersion(for: threadID)
        try requireThreadLiveness(for: threadID, version: livenessVersion)
        var thread: Thread

        if let memoryThread = threads[threadID] {
            thread = memoryThread
        } else {
            do {
                guard let dbThread = try await threadStore.fetchThread(id: threadID) else {
                    throw ThreadError.threadNotFound
                }
                thread = dbThread
                try requireThreadLiveness(for: threadID, version: livenessVersion)
            } catch let error as ThreadError {
                throw error
            } catch {
                logger.error("""
                attachWorkspace fetch failed — thread: \(threadID.uuidString.prefix(8)), \
                operation: fetchThread, error: \(ErrorKit.userFriendlyMessage(for: error))
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

        let originalThread = thread
        let attachmentMutation: (Thread, Bool) = try await withThreadAuthority(threadID) { [self, originalThread] in
            var candidate = originalThread
            let existingOwner = try await self.workspaceBindingRepository.threadID(for: workspaceId)
            if let existingOwner, existingOwner != threadID {
                throw WorkspaceBindingRepositoryError.workspaceAlreadyBound(
                    workspaceID: workspaceId,
                    threadID: existingOwner
                )
            }
            try await self.requireExecutionContextMutable(for: threadID)
            let claimed = existingOwner == nil
            if claimed {
                _ = try await self.workspaceBindingRepository.claim(
                    workspaceID: workspaceId,
                    for: threadID,
                    now: Date()
                )
            }
            do {
                try await self.requireExecutionContextMutable(for: threadID)
                if !candidate.attachedWorkspaceIDs.contains(workspaceId) {
                    // Compatibility projection only. Binding authority lives in the repository.
                    candidate.attachedWorkspaceIDs.append(workspaceId)
                }
                candidate.updatedAt = Date()
                try await self.threadStore.saveThread(candidate)
            } catch {
                if claimed {
                    _ = try? await self.workspaceBindingRepository.release(
                        workspaceID: workspaceId,
                        from: threadID,
                        now: Date()
                    )
                }
                throw error
            }
            return (candidate, claimed)
        }
        thread = attachmentMutation.0
        let claimedNewBinding = attachmentMutation.1
        do {
            try requireThreadLiveness(for: threadID, version: livenessVersion)
        } catch {
            // A deletion may have interleaved with the save itself. Remove a stale upsert so the
            // deleted thread cannot be resurrected even when persistence operations reorder.
            try? await self.threadStore.deleteThread(id: threadID)
            if claimedNewBinding {
                _ = try? await self.workspaceBindingRepository.release(
                    workspaceID: workspaceId,
                    from: threadID,
                    now: Date()
                )
            }
            throw error
        }
        if threads[thread.id] != nil { threads[thread.id] = thread }

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
                threadDegradations[threadID, default: []].append(TurnDiagnostic(
                    dependency: .workspace,
                    operation: "registerWorkspace",
                    entityID: "workspace:\(workspaceId.uuidString.prefix(8))",
                    errorIdentity: TurnEvent.ErrorIdentity.extracting(from: error),
                    message: ErrorKit.userFriendlyMessage(for: error)
                ))
            }
        }
    }

    func detachWorkspace(_ workspaceId: UUID, from threadID: UUID) async throws {
        try await requireExecutionContextMutable(for: threadID)
        var thread: Thread

        if let memoryThread = threads[threadID] {
            thread = memoryThread
        } else {
            do {
                guard let dbThread = try await threadStore.fetchThread(id: threadID) else {
                    throw ThreadError.threadNotFound
                }
                thread = dbThread
            } catch let error as ThreadError {
                throw error
            } catch {
                logger.error("""
                detachWorkspace fetch failed — thread: \(threadID.uuidString.prefix(8)), \
                operation: fetchThread, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                throw ThreadError.unavailable
            }
        }

        let originalThread = thread
        thread = try await withThreadAuthority(threadID) { [self, originalThread] in
            var candidate = originalThread
            let owner = try await self.workspaceBindingRepository.threadID(for: workspaceId)
            try await self.requireExecutionContextMutable(for: threadID)
            if owner == threadID {
                try await self.workspaceBindingRepository.release(
                    workspaceID: workspaceId,
                    from: threadID,
                    now: Date()
                )
            } else if let owner {
                throw WorkspaceBindingRepositoryError.workspaceAlreadyBound(
                    workspaceID: workspaceId,
                    threadID: owner
                )
            }
            do {
                try await self.requireExecutionContextMutable(for: threadID)
                candidate.attachedWorkspaceIDs.removeAll { $0 == workspaceId }
                candidate.updatedAt = Date()
                try await self.threadStore.saveThread(candidate)
            } catch {
                if owner == threadID {
                    _ = try? await self.workspaceBindingRepository.claim(
                        workspaceID: workspaceId,
                        for: threadID,
                        now: Date()
                    )
                }
                throw error
            }
            return candidate
        }
        if threads[thread.id] != nil { threads[thread.id] = thread }

        if let toolManager = toolManagers[threadID] {
            await toolManager.unregisterWorkspace(workspaceId)
        }
    }

    // MARK: - Workspace Lookup

    func getWorkspaces(for threadID: UUID) async throws -> WorkspaceQueryResult {
        let attachedIds: [UUID]

        if let thread = threads[threadID] {
            attachedIds = try await repositoryWorkspaceIDs(
                for: threadID,
                legacyIDs: thread.attachedWorkspaceIDs
            )
        } else {
            do {
                guard let thread = try await threadStore.fetchThread(id: threadID) else {
                    throw ThreadError.threadNotFound
                }
                attachedIds = try await repositoryWorkspaceIDs(
                    for: threadID,
                    legacyIDs: thread.attachedWorkspaceIDs
                )
            } catch let error as ThreadError {
                throw error
            } catch {
                logger.error("""
                getWorkspaces fetch failed — thread: \(threadID.uuidString.prefix(8)), \
                operation: fetchThread, error: \(ErrorKit.userFriendlyMessage(for: error))
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

extension ThreadManager {
    /// Reads repository bindings and imports legacy array projections only when needed. The
    /// mutable array remains for wire compatibility, but it is never consulted once a binding
    /// exists in the repository.
    func repositoryWorkspaceIDs(for threadID: UUID, legacyIDs: [UUID]) async throws -> [UUID] {
        var bindings = try await workspaceBindingRepository.bindings(for: threadID)
        if bindings.isEmpty, !legacyIDs.isEmpty {
            for workspaceID in legacyIDs {
                do {
                    _ = try await workspaceBindingRepository.claim(
                        workspaceID: workspaceID,
                        for: threadID,
                        now: Date()
                    )
                } catch let error as WorkspaceBindingRepositoryError {
                    logger.warning(
                        "Legacy Workspace binding import skipped: \(error.description)"
                    )
                }
            }
            bindings = try await workspaceBindingRepository.bindings(for: threadID)
        }
        return bindings.map(\.workspaceID)
    }
}

// MARK: - Workspace Status Normalization

private extension ThreadManager {
    /// Returns `.missing` for a `.runtime` workspace whose `rootPath` no longer exists on disk;
    /// leaves other workspaces (including `.attached` and `.runtimeThread`) unchanged.
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
