import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

// MARK: - Lifecycle

extension ThreadManager {
    /// Creates a new thread thread, initializes its workspace, and saves it to persistence.
    ///
    /// The thread record is persisted **first** so that a store failure leaves no orphan
    /// directories, workspace rows, or cached managers. If subsequent steps (directory creation,
    /// notes, workspace save) fail, the thread record and any partially created state are
    /// rolled back before rethrowing.
    ///
    /// Filesystem behavior is governed by the configured workspace profile (PKRR-029):
    /// - `.noWorkspace` (the default): no directory is created, no notes are written, no
    ///   workspace record is persisted, and `thread.workingDirectory` is `nil`.
    /// - `.ephemeralWorkspace`: a scratch directory is created under `root` and removed on
    ///   eviction/deletion.
    /// - `.hostManaged`: a directory is created under `root` (the host owns its retention).
    func createThread(title: String = "New Thread") async throws -> Thread {
        let threadID = UUID()

        let threadWorkspaceURL = workspaceRoot.appendingPathComponent(
            "threads", isDirectory: true
        )
        .appendingPathComponent(threadID.uuidString, isDirectory: true)

        // `.noWorkspace`: persist the thread record only. No directory, no notes, no
        // workspace row — a minimal thread has no filesystem side effects.
        guard workspaceProfile.provisionsThreadWorkspace else {
            let thread = Thread(
                id: threadID,
                title: title,
                attachedWorkspaceIDs: []
            )
            // workingDirectory stays nil: there is no workspace to point at.

            do {
                try await threadStore.saveThread(thread)
            } catch {
                logger.error("""
                createThread: thread persist failed — thread: \(threadID.uuidString.prefix(8)), \
                operation: saveThread, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                throw ThreadError.unavailable
            }

            threads[thread.id] = thread
            await setupThreadComponents(thread: thread, workspaceURL: threadWorkspaceURL)
            return thread
        }

        let workspace = WorkspaceReference(
            uri: .threadWorkspace(threadID),
            location: .runtime,
            rootPath: threadWorkspaceURL.path,
            trustLevel: .full
        )

        var thread = Thread(
            id: threadID,
            title: title,
            attachedWorkspaceIDs: [workspace.id]
        )
        thread.workingDirectory = threadWorkspaceURL.path

        do {
            try await threadStore.saveThread(thread)
        } catch {
            logger.error("""
            createThread: thread persist failed — thread: \(threadID.uuidString.prefix(8)), \
            operation: saveThread, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            throw ThreadError.unavailable
        }

        do {
            try FileManager.default.createDirectory(
                at: threadWorkspaceURL, withIntermediateDirectories: true
            )
            try writeSeedNotes(workspaceProfile.seedNotes, at: threadWorkspaceURL)
        } catch {
            logger.error("""
            createThread: workspace directory setup failed — \
            thread: \(threadID.uuidString.prefix(8)), \
            operation: createDirectory, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            try? await threadStore.deleteThread(id: threadID)
            throw ThreadError.unavailable
        }

        do {
            try await workspaceStore.saveWorkspace(workspace)
        } catch {
            logger.error("""
            createThread: workspace persist failed — \
            thread: \(threadID.uuidString.prefix(8)), \
            workspace: \(workspace.id.uuidString.prefix(8)), \
            operation: saveWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            // This directory was created by the failed transaction, so rollback removes it
            // regardless of the profile's long-term ownership policy. Host-managed ownership
            // applies after a successful commit, not to partially-created state.
            try? FileManager.default.removeItem(at: threadWorkspaceURL)
            try? await threadStore.deleteThread(id: threadID)
            throw ThreadError.unavailable
        }

        do {
            _ = try await workspaceBindingRepository.claim(
                workspaceID: workspace.id,
                for: thread.id,
                now: Date()
            )
        } catch {
            let message = "createThread: Workspace binding claim failed — thread: "
                + "\(thread.id.uuidString.prefix(8)), workspace: "
                + "\(workspace.id.uuidString.prefix(8)), error: "
                + "\(ErrorKit.userFriendlyMessage(for: error))"
            logger.error("\(message)")
            try? await workspaceStore.deleteWorkspace(id: workspace.id)
            try? await threadStore.deleteThread(id: thread.id)
            throw error
        }

        threads[thread.id] = thread
        await setupThreadComponents(thread: thread, workspaceURL: threadWorkspaceURL)

        return thread
    }

    /// Validates that a thread exists before a turn proceeds. Throws
    /// ``ThreadError/threadNotFound`` for unknown IDs and
    /// ``ThreadError/unavailable`` for transient store failures.
    func ensureThreadExists(id: UUID) async throws {
        do {
            try await hydrateThread(id: id)
        } catch let error as ThreadError {
            throw error
        } catch {
            throw ThreadError.unavailable
        }
    }

    /// Reconstructs a thread and its components from persistence.
    func hydrateThread(id: UUID) async throws {
        if toolManagers[id] != nil { return }

        guard let thread = try await threadStore.fetchThread(id: id) else {
            throw ThreadError.threadNotFound
        }

        let threadWorkspaceURL: URL
        if let workingDir = thread.workingDirectory {
            threadWorkspaceURL = URL(fileURLWithPath: workingDir)
        } else {
            threadWorkspaceURL = workspaceRoot.appendingPathComponent(
                "threads", isDirectory: true
            ).appendingPathComponent(id.uuidString, isDirectory: true)
        }

        threads[thread.id] = thread
        await setupThreadComponents(
            thread: thread,
            workspaceURL: threadWorkspaceURL
        )
    }

    /// Updates the title of a specific thread.
    func updateThreadTitle(_ threadID: UUID, title: String) async throws {
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
                updateThreadTitle fetch failed — thread: \(threadID.uuidString.prefix(8)), \
                operation: fetchThread, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                throw ThreadError.unavailable
            }
        }

        thread.title = title
        thread.updatedAt = Date()

        if threads[thread.id] != nil { threads[thread.id] = thread }
        try await threadStore.saveThread(thread)
    }

    /// Evicts all in-memory runtime state for a thread: the cached `Thread`,
    /// `TurnBriefingBuilder`, `ThreadToolRegistry`, thread degradations, and (when a
    /// prompt-history registry was injected) the journal-diff history entry. Does not touch
    /// persistence.
    ///
    /// Active generation work is cancelled and awaited (bounded cleanup) before cache eviction
    /// so streaming/tools/persistence/plugins cannot continue against a thread whose
    /// in-memory state has already been torn down.
    ///
    /// When the thread's configured workspace profile is `.ephemeralWorkspace`, the per-thread
    /// scratch directory is also removed (best-effort) — eviction ends the ephemeral workspace's
    /// life. `.hostManaged` directories are left in place (the host owns retention), and
    /// `.noWorkspace` has nothing to remove.
    ///
    /// This is the in-memory-only eviction seam. Callers that also want to remove the
    /// persisted thread, messages, and workspace attachments should call
    /// ``deleteThreadPermanently(id:)`` instead.
    func evictThreadFromMemory(id: UUID) async {
        await cancelActiveTaskAndAwait(for: id)

        // Ephemeral workspace cleanup: remove the scratch directory before dropping the cache
        // (the cache holds the path we need). Best-effort — eviction is non-throwing.
        if workspaceProfile.ownsDirectoryLifecycle,
           let workingDirectory = threads[id]?.workingDirectory
        {
            let dirURL = URL(fileURLWithPath: workingDirectory)
            if FileManager.default.fileExists(atPath: dirURL.path) {
                do {
                    try FileManager.default.removeItem(at: dirURL)
                } catch {
                    logger.warning("""
                    evictThreadFromMemory: ephemeral workspace cleanup failed — \
                    thread: \(id.uuidString.prefix(8)), \
                    path: \(workingDirectory), error: \(ErrorKit.userFriendlyMessage(for: error))
                    """)
                }
            }
        }

        threads.removeValue(forKey: id)
        turnBriefingBuilders.removeValue(forKey: id)
        toolManagers.removeValue(forKey: id)
        threadDegradations.removeValue(forKey: id)
        await promptHistoryRegistry?.removeHistory(for: id)
    }

    /// Evicts in-memory state without deleting persisted thread records.
    ///
    /// Use ``deleteThreadPermanently(id:)`` when durable deletion is required.
    func deleteThread(id: UUID) async {
        await evictThreadFromMemory(id: id)
    }

    /// Permanently deletes a thread and all related persisted records: the thread row, its
    /// messages, and thread-owned runtime workspace records. Caller-owned `.attached` and
    /// shared runtime workspaces are preserved. Active generation work is cancelled and drained
    /// (bounded cleanup) and in-memory state is evicted before persistence is touched.
    ///
    /// Each store deletion is best-effort: if one store fails, the remaining stores are still
    /// attempted and the failures are reported as `degradations` on the returned result. This
    /// avoids leaking partial state when only some stores are reachable. The result's
    /// `isComplete` is `true` only when every record was removed.
    ///
    /// - Parameter id: The thread to delete permanently.
    /// - Returns: A ``ThreadDeletionResult`` reporting any per-store cleanup failures.
    @discardableResult
    func deleteThreadPermanently(id: UUID) async -> ThreadDeletionResult {
        await threadAuthorityCoordinator.withThread(id) {
            await self.deleteThreadPermanentlyLocked(id: id)
        }
    }

    @discardableResult
    private func deleteThreadPermanentlyLocked(id: UUID) async -> ThreadDeletionResult {
        do {
            try await requireExecutionContextMutable(for: id)
        } catch {
            return ThreadDeletionResult(
                threadID: id,
                degradations: [StoreDegradation(
                    operation: "deleteThreadPermanently.activeTurn",
                    entityID: "thread:\(id.uuidString.prefix(8))",
                    error: error
                )]
            )
        }
        // Invalidate in-flight mutations before the first suspension. Actor reentrancy can let an
        // attachment resume after this point, so it must observe the new version before saving.
        invalidateThreadLiveness(for: id)

        var degradations: [StoreDegradation] = []

        // Capture attached workspace IDs (and the working directory, for ephemeral cleanup)
        // before eviction — once the cache is dropped we can no longer read them from memory,
        // and a store failure on fetch would otherwise strand workspace rows or leak a scratch
        // directory.
        var attachedWorkspaceIds: [UUID] = []
        var capturedWorkingDirectory: String?
        if let cached = threads[id] {
            attachedWorkspaceIds = cached.attachedWorkspaceIDs
            capturedWorkingDirectory = cached.workingDirectory
        } else {
            do {
                if let persisted = try await threadStore.fetchThread(id: id) {
                    attachedWorkspaceIds = persisted.attachedWorkspaceIDs
                    capturedWorkingDirectory = persisted.workingDirectory
                }
            } catch {
                degradations.append(StoreDegradation(
                    operation: "deleteThreadPermanently.fetchThread",
                    entityID: "thread:\(id.uuidString.prefix(8))",
                    error: error
                ))
            }
        }

        do {
            let repositoryBindings = try await workspaceBindingRepository.bindings(for: id)
            if !repositoryBindings.isEmpty {
                attachedWorkspaceIds = repositoryBindings.map(\.workspaceID)
            }
        } catch {
            degradations.append(StoreDegradation(
                operation: "deleteThreadPermanently.fetchWorkspaceBindings",
                entityID: "thread:\(id.uuidString.prefix(8))",
                error: error
            ))
        }

        // Cancel + drain active work, then evict in-memory state. This is the same bounded
        // cleanup `evictThreadFromMemory(id:)` performs, ensuring no stream/tool/plugin can
        // repopulate state or race with the persistence deletion below. Ephemeral workspace
        // cleanup runs inside eviction when the thread is cached.
        await evictThreadFromMemory(id: id)

        // Ephemeral workspace cleanup for the non-cached path: `evictThreadFromMemory` could
        // not see the working directory when the thread wasn't in memory, so clean it here.
        // Best-effort, like every other deletion step; `fileExists` makes this safe even when
        // eviction already removed the directory.
        if workspaceProfile.ownsDirectoryLifecycle, let workingDirectory = capturedWorkingDirectory {
            let dirURL = URL(fileURLWithPath: workingDirectory)
            if FileManager.default.fileExists(atPath: dirURL.path) {
                do {
                    try FileManager.default.removeItem(at: dirURL)
                } catch {
                    degradations.append(StoreDegradation(
                        operation: "deleteThreadPermanently.removeEphemeralDirectory",
                        entityID: "thread:\(id.uuidString.prefix(8))",
                        error: error
                    ))
                }
            }
        }

        // Delete messages (best-effort).
        do {
            try await messageStore.deleteMessages(for: id)
        } catch {
            degradations.append(StoreDegradation(
                operation: "deleteThreadPermanently.deleteMessages",
                entityID: "thread:\(id.uuidString.prefix(8))",
                error: error
            ))
        }

        // Resolve ownership before deleting workspace records. `.attached` workspaces belong to
        // the caller, while runtime workspaces can be shared; only thread-specific runtime
        // workspaces are eligible for deletion.
        var threadOwnedWorkspaceIds: [UUID] = []
        for workspaceId in attachedWorkspaceIds {
            do {
                guard let workspace = try await workspaceStore.fetchWorkspace(
                    id: workspaceId, includeTools: false
                ) else {
                    continue
                }

                let isThreadOwned = workspace.location == .runtimeThread
                    || (workspace.location == .runtime
                        && workspace.uri == .threadWorkspace(id))
                if isThreadOwned, !threadOwnedWorkspaceIds.contains(workspaceId) {
                    threadOwnedWorkspaceIds.append(workspaceId)
                }
            } catch {
                degradations.append(StoreDegradation(
                    operation: "deleteThreadPermanently.fetchWorkspaceOwnership",
                    entityID: "workspace:\(workspaceId.uuidString.prefix(8))",
                    error: error
                ))
            }
        }

        // A thread-specific runtime workspace may still be shared by another thread. Keep it
        // when ownership cannot be established exclusively for this deletion.
        if !threadOwnedWorkspaceIds.isEmpty {
            do {
                let otherThreadWorkspaceIds = Set(
                    try await threadStore
                        .fetchAllThreads(includeArchived: true)
                        .filter { $0.id != id }
                        .flatMap(\.attachedWorkspaceIDs)
                )
                threadOwnedWorkspaceIds.removeAll { otherThreadWorkspaceIds.contains($0) }
            } catch {
                degradations.append(StoreDegradation(
                    operation: "deleteThreadPermanently.fetchWorkspaceReferences",
                    entityID: "thread:\(id.uuidString.prefix(8))",
                    error: error
                ))
                threadOwnedWorkspaceIds.removeAll()
            }
        }

        // Delete thread-owned workspace records (best-effort, per-workspace). Caller-owned and
        // shared workspaces remain persisted, and the deleted thread row removes their links.
        for workspaceId in threadOwnedWorkspaceIds {
            do {
                try await workspaceStore.deleteWorkspace(id: workspaceId)
            } catch {
                degradations.append(StoreDegradation(
                operation: "deleteThreadPermanently.deleteWorkspace",
                    entityID: "workspace:\(workspaceId.uuidString.prefix(8))",
                    error: error
                ))
            }
        }

        for workspaceId in attachedWorkspaceIds {
            do {
                if try await workspaceBindingRepository.threadID(for: workspaceId) == id {
                    try await workspaceBindingRepository.release(
                        workspaceID: workspaceId,
                        from: id,
                        now: Date()
                    )
                }
            } catch {
                degradations.append(StoreDegradation(
                    operation: "deleteThreadPermanently.releaseWorkspaceBinding",
                    entityID: "workspace:\(workspaceId.uuidString.prefix(8))",
                    error: error
                ))
            }
        }

        // Delete the thread record last, so messages and workspaces are cleaned up before
        // the parent row disappears (mirrors `createThread`'s persist-first ordering).
        do {
            try await threadStore.deleteThread(id: id)
        } catch {
            degradations.append(StoreDegradation(
                operation: "deleteThreadPermanently.deleteThread",
                entityID: "thread:\(id.uuidString.prefix(8))",
                error: error
            ))
        }

        completeThreadDeletionLiveness(for: id)

        if !degradations.isEmpty {
            logger.warning("""
            deleteThreadPermanently: partial cleanup — thread: \(id.uuidString.prefix(8)), \
            failures: \(degradations.count), operations: \(degradations.map(\.operation).joined(separator: ", "))
            """)
        }

        return ThreadDeletionResult(threadID: id, degradations: degradations)
    }

    /// Removes active threads from memory that have not been updated within the specified
    /// interval. Evicts in-memory state only; persisted threads are unaffected. Also drops
    /// the corresponding prompt-history entries when a registry was injected.
    func cleanupStaleThreads(maxAge: TimeInterval) async {
        let now = Date()
        let staleIds = Array(threads.values).filter { thread in
            now.timeIntervalSince(thread.updatedAt) > maxAge
        }.map { $0.id }

        for id in staleIds {
            await evictThreadFromMemory(id: id)
        }
    }
}

// MARK: - Component Setup & Eviction

private extension ThreadManager {
    /// Initializes and configures the internal components for a thread thread.
    func setupThreadComponents(
        thread: Thread,
        workspaceURL: URL
    ) async {
        let attachedWorkspaceIDs = (try? await repositoryWorkspaceIDs(
            for: thread.id,
            legacyIDs: thread.attachedWorkspaceIDs
        )) ?? thread.attachedWorkspaceIDs
        let contextWorkspace: (any Workspace)?
        if let firstId = attachedWorkspaceIDs.first {
            do {
                contextWorkspace = try await workspaceResolver.workspace(id: firstId)
            } catch {
                logger.warning("""
                setupThreadComponents: context workspace resolution failed — \
                workspace: \(firstId.uuidString.prefix(8)), thread: \(thread.id.uuidString.prefix(8)), \
                operation: resolveContextWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                threadDegradations[thread.id, default: []].append(TurnDiagnostic(
                    dependency: .workspace,
                    operation: "resolveContextWorkspace",
                    entityID: "workspace:\(firstId.uuidString.prefix(8))",
                    errorIdentity: TurnEvent.ErrorIdentity.extracting(from: error),
                    message: ErrorKit.userFriendlyMessage(for: error)
                ))
                contextWorkspace = nil
            }
        } else {
            contextWorkspace = nil
        }

        let turnBriefingBuilder = TurnBriefingBuilder(
            workspace: contextWorkspace,
            memoryStore: memoryStore
        )
        turnBriefingBuilders[thread.id] = turnBriefingBuilder

        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: thread,
            jailRoot: workspaceURL.path,
            runtimeToolPolicy: runtimeToolPolicy,
            threadStore: threadStore,
            messageStore: messageStore
        )
        toolManagers[thread.id] = toolManager

        for attachedId in attachedWorkspaceIDs {
            do {
                if let workspace = try await workspaceResolver.workspace(id: attachedId) {
                    await toolManager.registerWorkspace(workspace)
                }
            } catch {
                logger.warning("""
                setupThreadComponents: attached workspace registration failed — \
                workspace: \(attachedId.uuidString.prefix(8)), thread: \(thread.id.uuidString.prefix(8)), \
                operation: registerAttachedWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                threadDegradations[thread.id, default: []].append(TurnDiagnostic(
                    dependency: .workspace,
                    operation: "registerAttachedWorkspace",
                    entityID: "workspace:\(attachedId.uuidString.prefix(8))",
                    errorIdentity: TurnEvent.ErrorIdentity.extracting(from: error),
                    message: ErrorKit.userFriendlyMessage(for: error)
                ))
            }
        }
    }

    /// Writes the configured seed notes into a freshly created thread workspace's `Notes/`
    /// directory (PKRR-029).
    ///
    /// Replaces the former unconditional `writeSeedNotes(at:)` which always wrote
    /// `Welcome.md` and `Project.md`. The notes written are now governed by the thread's
    /// ``ThreadManager/workspaceProfile``; pass ``WorkspaceSeedNotes/none`` to write nothing.
    func writeSeedNotes(_ seedNotes: WorkspaceSeedNotes, at workspaceURL: URL) throws {
        guard !seedNotes.notes.isEmpty else { return }

        let notesDir = workspaceURL.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        for note in seedNotes.notes {
            let destination = notesDir.appendingPathComponent(note.filename)
            try note.content.write(
                to: destination,
                atomically: true, encoding: .utf8
            )
        }
    }
}
