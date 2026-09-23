import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

// MARK: - Lifecycle

extension TimelineManager {
    /// Creates a new timeline, initializes its workspace, and saves it to persistence.
    ///
    /// The timeline record is persisted **first** so that a store failure leaves no orphan
    /// directories, workspace rows, or cached managers. If subsequent steps (directory creation,
    /// notes, workspace save) fail, the timeline record and any partially created state are
    /// rolled back before rethrowing.
    ///
    /// Filesystem behavior is governed by the configured workspace profile (PKRR-029):
    /// - `.noWorkspace` (the default): no directory is created, no notes are written, no
    ///   workspace record is persisted, and `timeline.workingDirectory` is `nil`.
    /// - `.ephemeralWorkspace`: a scratch directory is created under `root` and removed on
    ///   eviction/deletion.
    /// - `.hostManaged`: a directory is created under `root` (the host owns its retention).
    func createTimeline(
        title: String = "New Timeline",
        attachedAgentID: UUID? = nil
    ) async throws -> TimelineRecord {
        let timelineID = UUID()

        let timelineWorkspaceURL = workspaceRoot.appendingPathComponent(
            "threads", isDirectory: true
        )
        .appendingPathComponent(timelineID.uuidString, isDirectory: true)

        // `.noWorkspace`: persist the timeline record only. No directory, no notes, no
        // workspace row — a minimal timeline has no filesystem side effects.
        guard workspaceProfile.provisionsTimelineWorkspace else {
            let timeline = TimelineRecord(
                id: timelineID,
                title: title,
                attachedAgentID: attachedAgentID
            )
            // workingDirectory stays nil: there is no workspace to point at.

            do {
                try await timelineStore.saveTimeline(timeline)
            } catch {
                logger.error("""
                createTimeline: timeline persist failed — timeline: \(timelineID.uuidString.prefix(8)), \
                operation: saveTimeline, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                throw TimelineError.unavailable
            }

            timelines[timeline.id] = timeline
            await setupTimelineComponents(timeline: timeline, workspaceURL: timelineWorkspaceURL)
            return timeline
        }

        let workspace = WorkspaceReference(
            uri: .timelineWorkspace(timelineID),
            location: .runtime,
            rootPath: timelineWorkspaceURL.path,
            trustLevel: .full
        )

        var timeline = TimelineRecord(
            id: timelineID,
            title: title,
            attachedAgentID: attachedAgentID
        )
        timeline.workingDirectory = timelineWorkspaceURL.path

        do {
            try await timelineStore.saveTimeline(timeline)
        } catch {
            logger.error("""
            createTimeline: timeline persist failed — timeline: \(timelineID.uuidString.prefix(8)), \
            operation: saveTimeline, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            throw TimelineError.unavailable
        }

        do {
            try FileManager.default.createDirectory(
                at: timelineWorkspaceURL, withIntermediateDirectories: true
            )
            try writeSeedNotes(workspaceProfile.seedNotes, at: timelineWorkspaceURL)
        } catch {
            logger.error("""
            createTimeline: workspace directory setup failed — \
            timeline: \(timelineID.uuidString.prefix(8)), \
            operation: createDirectory, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            try? await timelineStore.deleteTimeline(id: timelineID)
            throw TimelineError.unavailable
        }

        do {
            try await workspaceStore.saveWorkspace(workspace)
        } catch {
            logger.error("""
            createTimeline: workspace persist failed — \
            timeline: \(timelineID.uuidString.prefix(8)), \
            workspace: \(workspace.id.uuidString.prefix(8)), \
            operation: saveWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            // This directory was created by the failed transaction, so rollback removes it
            // regardless of the profile's long-term ownership policy. Host-managed ownership
            // applies after a successful commit, not to partially-created state.
            try? FileManager.default.removeItem(at: timelineWorkspaceURL)
            try? await timelineStore.deleteTimeline(id: timelineID)
            throw TimelineError.unavailable
        }

        do {
            _ = try await workspaceBindingRepository.claim(
                workspaceID: workspace.id,
                for: timeline.id,
                now: Date()
            )
        } catch {
            let message = "createTimeline: Workspace binding claim failed — timeline: "
                + "\(timeline.id.uuidString.prefix(8)), workspace: "
                + "\(workspace.id.uuidString.prefix(8)), error: "
                + "\(ErrorKit.userFriendlyMessage(for: error))"
            logger.error("\(message)")
            try? await workspaceStore.deleteWorkspace(id: workspace.id)
            try? await timelineStore.deleteTimeline(id: timeline.id)
            throw error
        }

        timelines[timeline.id] = timeline
        await setupTimelineComponents(timeline: timeline, workspaceURL: timelineWorkspaceURL)

        return timeline
    }

    /// Validates that a timeline exists before a turn proceeds. Throws
    /// ``TimelineError/timelineNotFound`` for unknown IDs and
    /// ``TimelineError/unavailable`` for transient store failures.
    func ensureTimelineExists(id: UUID) async throws {
        do {
            try await hydrateTimeline(id: id)
        } catch let error as TimelineError {
            throw error
        } catch {
            throw TimelineError.unavailable
        }
    }

    /// Reconstructs a timeline and its components from persistence.
    func hydrateTimeline(id: UUID) async throws {
        if toolManagers[id] != nil { return }

        guard let timeline = try await timelineStore.fetchTimeline(id: id) else {
            throw TimelineError.timelineNotFound
        }

        let timelineWorkspaceURL: URL
        if let workingDir = timeline.workingDirectory {
            timelineWorkspaceURL = URL(fileURLWithPath: workingDir)
        } else {
            timelineWorkspaceURL = workspaceRoot.appendingPathComponent(
                "threads", isDirectory: true
            ).appendingPathComponent(id.uuidString, isDirectory: true)
        }

        timelines[timeline.id] = timeline
        await setupTimelineComponents(
            timeline: timeline,
            workspaceURL: timelineWorkspaceURL
        )
        await classifyActiveTurnOnLoad(for: id)
    }

    /// Interrupts an active Turn this process does not own when the Timeline is loaded, so an
    /// orphan from an earlier or crashed process is recovered even when nothing is sent next
    /// (ADR 0010). A Turn this process is driving or preparing, or whose terminal commit is still
    /// pending, stays busy; when the store cannot answer whether a side effect is pending, the
    /// Turn is left busy rather than interrupted without evidence.
    private func classifyActiveTurnOnLoad(for timelineID: UUID) async {
        guard let finalizer else { return }
        guard let active = try? await runtimeRepository.fetchActiveTurn(for: timelineID) else { return }
        let activeTurnID = active.identity.turnID
        guard await taskRegistry.activeTurnID(for: timelineID) != activeTurnID,
              await finalizer.pendingCommitStartedAt(turnID: activeTurnID) == nil
        else {
            return
        }
        do {
            let disposition = try await TurnAbandonment.disposition(
                for: activeTurnID,
                repository: runtimeRepository
            )
            _ = try await runtimeRepository.interruptTurn(
                turnID: activeTurnID,
                reason: "Turn was active but not owned by this runtime (orphaned).",
                disposition: disposition,
                now: Date()
            )
        } catch {
            logger.warning("""
            classifyActiveTurnOnLoad: unable to classify active Turn — \
            timeline: \(timelineID.uuidString.prefix(8)), \
            turn: \(activeTurnID.uuidString.prefix(8)), error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
        }
    }

    /// Updates the title of a specific timeline.
    func updateTimelineTitle(_ timelineID: UUID, title: String) async throws {
        var timeline = try await cachedOrStoredTimeline(timelineID, operation: "updateTimelineTitle")
        timeline.title = title
        timeline.updatedAt = Date()

        replaceCachedTimelineIfPresent(timeline)
        try await timelineStore.saveTimeline(timeline)
    }

    /// Evicts all in-memory runtime state for a Timeline: its cached metadata,
    /// `TimelineToolRegistry`, timeline degradations, and (when a
    /// prompt-history registry was injected) the journal-diff history entry. Does not touch
    /// persistence.
    ///
    /// Eviction has two phases (ADR 0010). Phase one bumps the Timeline liveness version,
    /// cancels the active Turn, and rejects new work against the torn-down Timeline. Phase two
    /// removes the ephemeral workspace directory and drops the cached registries once the Turn
    /// task exits. The Turn task no longer waits on the store — its terminal commit runs in the
    /// runtime-owned finalizer — so a hung store commit cannot stall either phase. Streaming and
    /// tools still stop before their workspace directory is removed.
    ///
    /// When the timeline's configured workspace profile is `.ephemeralWorkspace`, the per-timeline
    /// scratch directory is also removed (best-effort) — eviction ends the ephemeral workspace's
    /// life. `.hostManaged` directories are left in place (the host owns retention), and
    /// `.noWorkspace` has nothing to remove.
    ///
    /// This is the in-memory-only eviction seam. Callers that also want to remove the
    /// persisted timeline, messages, and workspace attachments should call
    /// ``deleteTimelinePermanently(id:)`` instead.
    func evictTimelineFromMemory(id: UUID) async {
        // Phase one: reject in-flight mutations, then cancel the Turn. Joining the Turn task is
        // bounded because the terminal commit is no longer part of that task.
        bumpTimelineLiveness(for: id)
        await cancelActiveTaskAndAwait(for: id)

        // Phase two: remove the scratch directory before dropping the cache (the cache holds the
        // path we need), then release the remaining registries. Best-effort — eviction is
        // non-throwing.
        if workspaceProfile.ownsDirectoryLifecycle,
           let workingDirectory = timelines[id]?.workingDirectory
        {
            let dirURL = URL(fileURLWithPath: workingDirectory)
            if FileManager.default.fileExists(atPath: dirURL.path) {
                do {
                    try FileManager.default.removeItem(at: dirURL)
                } catch {
                    logger.warning("""
                    evictTimelineFromMemory: ephemeral workspace cleanup failed — \
                    timeline: \(id.uuidString.prefix(8)), \
                    path: \(workingDirectory), error: \(ErrorKit.userFriendlyMessage(for: error))
                    """)
                }
            }
        }

        timelines.removeValue(forKey: id)
        toolManagers.removeValue(forKey: id)
        timelineDegradations.removeValue(forKey: id)
        await promptHistoryRegistry?.removeHistory(for: id)
    }

    /// Permanently deletes a timeline and all related persisted records: the timeline row, its
    /// messages, and timeline-owned runtime workspace records. Caller-owned `.attached` and
    /// shared runtime workspaces are preserved. Active generation work is cancelled and drained
    /// (bounded cleanup) and in-memory state is evicted before persistence is touched.
    ///
    /// Each store deletion is best-effort: if one store fails, the remaining stores are still
    /// attempted and the failures are reported as `degradations` on the returned result. This
    /// avoids leaking partial state when only some stores are reachable. The result's
    /// `isComplete` is `true` only when every record was removed.
    ///
    /// - Parameter id: The timeline to delete permanently.
    /// - Returns: A ``TimelineDeletionResult`` reporting any per-store cleanup failures.
    @discardableResult
    func deleteTimelinePermanently(id: UUID) async -> TimelineDeletionResult {
        do {
            return try await timelineAuthorityCoordinator.withTimeline(id) {
                await self.deleteTimelinePermanentlyLocked(id: id)
            }
        } catch {
            // The Timeline authority lane throws `CancellationError` when the calling task is
            // cancelled while queued (or immediately after acquiring the lane), and never runs
            // `deleteTimelinePermanentlyLocked` in that case. Report it as a degradation rather
            // than silently completing the deletion despite the caller's cancellation, or
            // propagating a throw from a documented non-throwing API.
            return TimelineDeletionResult(
                timelineID: id,
                degradations: [StoreDegradation(
                    operation: "deleteTimelinePermanently.cancelled",
                    entityID: "timeline:\(id.uuidString.prefix(8))",
                    error: error
                )]
            )
        }
    }

    @discardableResult
    private func deleteTimelinePermanentlyLocked(id: UUID) async -> TimelineDeletionResult {
        do {
            try await requireExecutionContextMutable(for: id)
        } catch {
            return TimelineDeletionResult(
                timelineID: id,
                degradations: [StoreDegradation(
                    operation: "deleteTimelinePermanently.activeTurn",
                    entityID: "timeline:\(id.uuidString.prefix(8))",
                    error: error
                )]
            )
        }
        // Invalidate in-flight mutations before the first suspension. Actor reentrancy can let an
        // attachment resume after this point, so it must observe the new version before saving.
        invalidateTimelineLiveness(for: id)

        var degradations: [StoreDegradation] = []

        // Capture repository-owned workspace bindings (and the working directory, for ephemeral
        // cleanup) before eviction — once the cache is dropped we can no longer read the timeline
        // from memory, and a store failure on fetch would otherwise strand workspace rows or leak
        // a scratch directory.
        var workspaceIDs: [UUID] = []
        var capturedWorkingDirectory: String?
        if let cached = timelines[id] {
            capturedWorkingDirectory = cached.workingDirectory
        } else {
            do {
                if let persisted = try await timelineStore.fetchTimeline(id: id) {
                    capturedWorkingDirectory = persisted.workingDirectory
                }
            } catch {
                degradations.append(StoreDegradation(
                    operation: "deleteTimelinePermanently.fetchTimeline",
                    entityID: "timeline:\(id.uuidString.prefix(8))",
                    error: error
                ))
            }
        }

        do {
            workspaceIDs = try await workspaceBindingRepository
                .bindings(for: id)
                .map(\.workspaceID)
        } catch {
            degradations.append(StoreDegradation(
                operation: "deleteTimelinePermanently.fetchWorkspaceBindings",
                entityID: "timeline:\(id.uuidString.prefix(8))",
                error: error
            ))
        }

        // Cancel + drain active work, then evict in-memory state. This is the same bounded
        // cleanup `evictTimelineFromMemory(id:)` performs, ensuring no stream/tool/plugin can
        // repopulate state or race with the persistence deletion below. Ephemeral workspace
        // cleanup runs inside eviction when the timeline is cached.
        await evictTimelineFromMemory(id: id)

        // Ephemeral workspace cleanup for the non-cached path: `evictTimelineFromMemory` could
        // not see the working directory when the timeline wasn't in memory, so clean it here.
        // Best-effort, like every other deletion step; `fileExists` makes this safe even when
        // eviction already removed the directory.
        if workspaceProfile.ownsDirectoryLifecycle, let workingDirectory = capturedWorkingDirectory {
            let dirURL = URL(fileURLWithPath: workingDirectory)
            if FileManager.default.fileExists(atPath: dirURL.path) {
                do {
                    try FileManager.default.removeItem(at: dirURL)
                } catch {
                    degradations.append(StoreDegradation(
                        operation: "deleteTimelinePermanently.removeEphemeralDirectory",
                        entityID: "timeline:\(id.uuidString.prefix(8))",
                        error: error
                    ))
                }
            }
        }

        // Message history is no longer deleted here: `timelineStore.deleteTimeline(id:)` below
        // cascades history deletion as part of destroying the timeline record (see the
        // `TimelineRuntimeRepository` cascade contract). Ordinary append-only history remains
        // immutable while the timeline is alive; only destroying the timeline destroys its history.

        // Resolve ownership before deleting workspace records. `.attached` workspaces belong to
        // the caller, while runtime workspaces can be shared; only timeline-specific runtime
        // workspaces are eligible for deletion.
        var timelineOwnedWorkspaceIds: [UUID] = []
        for workspaceId in workspaceIDs {
            do {
                guard let workspace = try await workspaceStore.fetchWorkspace(
                    id: workspaceId, includeTools: false
                ) else {
                    continue
                }

                let isTimelineOwned = workspace.location == .runtimeTimeline
                    || (workspace.location == .runtime
                        && workspace.uri == .timelineWorkspace(id))
                if isTimelineOwned, !timelineOwnedWorkspaceIds.contains(workspaceId) {
                    timelineOwnedWorkspaceIds.append(workspaceId)
                }
            } catch {
                degradations.append(StoreDegradation(
                    operation: "deleteTimelinePermanently.fetchWorkspaceOwnership",
                    entityID: "workspace:\(workspaceId.uuidString.prefix(8))",
                    error: error
                ))
            }
        }

        // Delete timeline-owned workspace records (best-effort, per-workspace). Caller-owned and
        // shared workspaces remain persisted, and the deleted timeline row removes their links.
        for workspaceId in timelineOwnedWorkspaceIds {
            do {
                try await workspaceStore.deleteWorkspace(id: workspaceId)
            } catch {
                degradations.append(StoreDegradation(
                operation: "deleteTimelinePermanently.deleteWorkspace",
                    entityID: "workspace:\(workspaceId.uuidString.prefix(8))",
                    error: error
                ))
            }
        }

        for workspaceId in workspaceIDs {
            do {
                if try await workspaceBindingRepository.timelineID(for: workspaceId) == id {
                    try await workspaceBindingRepository.release(
                        workspaceID: workspaceId,
                        from: id,
                        now: Date()
                    )
                }
            } catch {
                degradations.append(StoreDegradation(
                    operation: "deleteTimelinePermanently.releaseWorkspaceBinding",
                    entityID: "workspace:\(workspaceId.uuidString.prefix(8))",
                    error: error
                ))
            }
        }

        // Delete the timeline record last, so messages and workspaces are cleaned up before
        // the parent row disappears (mirrors `createTimeline`'s persist-first ordering).
        do {
            try await timelineStore.deleteTimeline(id: id)
        } catch {
            degradations.append(StoreDegradation(
                operation: "deleteTimelinePermanently.deleteTimeline",
                entityID: "timeline:\(id.uuidString.prefix(8))",
                error: error
            ))
        }

        completeTimelineDeletionLiveness(for: id)

        if !degradations.isEmpty {
            logger.warning("""
            deleteTimelinePermanently: partial cleanup — timeline: \(id.uuidString.prefix(8)), \
            failures: \(degradations.count), operations: \(degradations.map(\.operation).joined(separator: ", "))
            """)
        }

        return TimelineDeletionResult(timelineID: id, degradations: degradations)
    }

    /// Removes active timelines from memory that have not been updated within the specified
    /// interval. Evicts in-memory state only; persisted timelines are unaffected. Also drops
    /// the corresponding prompt-history entries when a registry was injected.
    func cleanupStaleTimelines(maxAge: TimeInterval) async {
        let now = Date()
        let staleIds = Array(timelines.values).filter { timeline in
            now.timeIntervalSince(timeline.updatedAt) > maxAge
        }.map { $0.id }

        for id in staleIds {
            await evictTimelineFromMemory(id: id)
        }
    }
}

// MARK: - Component Setup & Eviction

private extension TimelineManager {
    /// Initializes and configures the internal components for a timeline.
    func setupTimelineComponents(
        timeline: TimelineRecord,
        workspaceURL: URL
    ) async {
        let workspaceIDs: [UUID]
        do {
            workspaceIDs = try await workspaceBindingRepository
                .bindings(for: timeline.id)
                .map(\.workspaceID)
        } catch {
            logger.warning("""
            setupTimelineComponents: workspace binding lookup failed — \
            timeline: \(timeline.id.uuidString.prefix(8)), \
            operation: fetchWorkspaceBindings, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            timelineDegradations[timeline.id, default: []].append(TurnDiagnostic(
                dependency: .workspace,
                operation: "fetchWorkspaceBindings",
                entityID: "timeline:\(timeline.id.uuidString.prefix(8))",
                error: error
            ))
            workspaceIDs = []
        }
        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: timeline,
            jailRoot: workspaceURL.path,
            runtimeToolPolicy: runtimeToolPolicy,
            timelineStore: timelineStore,
            messageStore: messageStore
        )
        toolManagers[timeline.id] = toolManager

        for attachedId in workspaceIDs {
            do {
                if let workspace = try await workspaceResolver.workspace(id: attachedId) {
                    await toolManager.registerWorkspace(workspace)
                }
            } catch {
                logger.warning("""
                setupTimelineComponents: attached workspace registration failed — \
                workspace: \(attachedId.uuidString.prefix(8)), timeline: \(timeline.id.uuidString.prefix(8)), \
                operation: registerAttachedWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                timelineDegradations[timeline.id, default: []].append(TurnDiagnostic(
                    dependency: .workspace,
                    operation: "registerAttachedWorkspace",
                    entityID: "workspace:\(attachedId.uuidString.prefix(8))",
                    error: error
                ))
            }
        }
    }

    /// Writes the configured seed notes into a freshly created timeline workspace's `Notes/`
    /// directory (PKRR-029).
    ///
    /// Replaces the former unconditional `writeSeedNotes(at:)` which always wrote
    /// `Welcome.md` and `Project.md`. The notes written are now governed by the timeline's
    /// ``TimelineManager/workspaceProfile``; pass ``WorkspaceSeedNotes/none`` to write nothing.
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
