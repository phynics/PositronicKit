import ErrorKit
import Foundation
import Logging
import PKShared
import PKUtilities

// MARK: - Lifecycle

public extension TimelineManager {
    /// Creates a new conversation timeline, initializes its workspace, and saves it to persistence.
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
    func createTimeline(title: String = "New Conversation") async throws -> Timeline {
        let timelineId = UUID()

        let timelineWorkspaceURL = workspaceRoot.appendingPathComponent(
            "timelines", isDirectory: true
        )
        .appendingPathComponent(timelineId.uuidString, isDirectory: true)

        // `.noWorkspace`: persist the timeline record only. No directory, no notes, no
        // workspace row — a minimal timeline has no filesystem side effects.
        guard workspaceProfile.provisionsTimelineWorkspace else {
            let timeline = Timeline(
                id: timelineId,
                title: title,
                attachedWorkspaceIds: []
            )
            // workingDirectory stays nil: there is no workspace to point at.

            do {
                try await timelineStore.saveTimeline(timeline)
            } catch {
                logger.error("""
                createTimeline: timeline persist failed — timeline: \(timelineId.uuidString.prefix(8)), \
                operation: saveTimeline, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                throw TimelineError.unavailable
            }

            timelines[timeline.id] = timeline
            await setupTimelineComponents(timeline: timeline, workspaceURL: timelineWorkspaceURL)
            return timeline
        }

        let workspace = WorkspaceReference(
            uri: .timelineWorkspace(timelineId),
            location: .runtime,
            rootPath: timelineWorkspaceURL.path,
            trustLevel: .full
        )

        var timeline = Timeline(
            id: timelineId,
            title: title,
            attachedWorkspaceIds: [workspace.id]
        )
        timeline.workingDirectory = timelineWorkspaceURL.path

        do {
            try await timelineStore.saveTimeline(timeline)
        } catch {
            logger.error("""
            createTimeline: timeline persist failed — timeline: \(timelineId.uuidString.prefix(8)), \
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
            timeline: \(timelineId.uuidString.prefix(8)), \
            operation: createDirectory, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            try? await timelineStore.deleteTimeline(id: timelineId)
            throw TimelineError.unavailable
        }

        do {
            try await workspaceStore.saveWorkspace(workspace)
        } catch {
            logger.error("""
            createTimeline: workspace persist failed — \
            timeline: \(timelineId.uuidString.prefix(8)), \
            workspace: \(workspace.id.uuidString.prefix(8)), \
            operation: saveWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            // This directory was created by the failed transaction, so rollback removes it
            // regardless of the profile's long-term ownership policy. Host-managed ownership
            // applies after a successful commit, not to partially-created state.
            try? FileManager.default.removeItem(at: timelineWorkspaceURL)
            try? await timelineStore.deleteTimeline(id: timelineId)
            throw TimelineError.unavailable
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
                "timelines", isDirectory: true
            ).appendingPathComponent(id.uuidString, isDirectory: true)
        }

        timelines[timeline.id] = timeline
        await setupTimelineComponents(
            timeline: timeline,
            workspaceURL: timelineWorkspaceURL
        )
    }

    /// Updates the title of a specific timeline.
    func updateTimelineTitle(id: UUID, title: String) async throws {
        var timeline: Timeline
        if let memoryTimeline = timelines[id] {
            timeline = memoryTimeline
        } else {
            do {
                guard let dbTimeline = try await timelineStore.fetchTimeline(id: id) else {
                    throw TimelineError.timelineNotFound
                }
                timeline = dbTimeline
            } catch let error as TimelineError {
                throw error
            } catch {
                logger.error("""
                updateTimelineTitle fetch failed — timeline: \(id.uuidString.prefix(8)), \
                operation: fetchTimeline, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                throw TimelineError.unavailable
            }
        }

        timeline.title = title
        timeline.updatedAt = Date()

        if timelines[timeline.id] != nil { timelines[timeline.id] = timeline }
        try await timelineStore.saveTimeline(timeline)
    }

    /// Evicts all in-memory runtime state for a timeline: the cached `Timeline`,
    /// `TurnBriefingBuilder`, `TimelineToolRegistry`, timeline degradations, and (when a
    /// prompt-history registry was injected) the journal-diff history entry. Does not touch
    /// persistence.
    ///
    /// Active generation work is cancelled and awaited (bounded cleanup) before cache eviction
    /// so streaming/tools/persistence/plugins cannot continue against a timeline whose
    /// in-memory state has already been torn down.
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
        await cancelActiveTaskAndAwait(for: id)

        // Ephemeral workspace cleanup: remove the scratch directory before dropping the cache
        // (the cache holds the path we need). Best-effort — eviction is non-throwing.
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
        turnBriefingBuilders.removeValue(forKey: id)
        toolManagers.removeValue(forKey: id)
        timelineDegradations.removeValue(forKey: id)
        await promptHistoryRegistry?.removeHistory(for: id)
    }

    /// Deprecated alias for ``evictTimelineFromMemory(id:)``.
    ///
    /// The name `deleteTimeline` suggested durable deletion, but this method only evicts
    /// in-memory state — it neither cancels persisted records nor (before PKRR-002) guaranteed
    /// active-work drainage. Use ``evictTimelineFromMemory(id:)`` for memory-only eviction, or
    /// ``deleteTimelinePermanently(id:)`` to also remove persisted records.
    @available(*, deprecated, renamed: "evictTimelineFromMemory(id:)")
    func deleteTimeline(id: UUID) async {
        await evictTimelineFromMemory(id: id)
    }

    /// Permanently deletes a timeline and all related persisted records: the timeline row, its
    /// messages, and any attached workspace records. Active generation work is cancelled and
    /// drained (bounded cleanup) and in-memory state is evicted before persistence is touched.
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
        var degradations: [StoreDegradation] = []

        // Capture attached workspace IDs (and the working directory, for ephemeral cleanup)
        // before eviction — once the cache is dropped we can no longer read them from memory,
        // and a store failure on fetch would otherwise strand workspace rows or leak a scratch
        // directory.
        var attachedWorkspaceIds: [UUID] = []
        var capturedWorkingDirectory: String?
        if let cached = timelines[id] {
            attachedWorkspaceIds = cached.attachedWorkspaceIds
            capturedWorkingDirectory = cached.workingDirectory
        } else {
            do {
                if let persisted = try await timelineStore.fetchTimeline(id: id) {
                    attachedWorkspaceIds = persisted.attachedWorkspaceIds
                    capturedWorkingDirectory = persisted.workingDirectory
                }
            } catch {
                degradations.append(StoreDegradation(
                    operation: "deleteTimelinePermanently.fetchTimeline",
                    entityId: "timeline:\(id.uuidString.prefix(8))",
                    error: error
                ))
            }
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
                        entityId: "timeline:\(id.uuidString.prefix(8))",
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
                operation: "deleteTimelinePermanently.deleteMessages",
                entityId: "timeline:\(id.uuidString.prefix(8))",
                error: error
            ))
        }

        // Delete attached workspace records (best-effort, per-workspace).
        for workspaceId in attachedWorkspaceIds {
            do {
                try await workspaceStore.deleteWorkspace(id: workspaceId)
            } catch {
                degradations.append(StoreDegradation(
                    operation: "deleteTimelinePermanently.deleteWorkspace",
                    entityId: "workspace:\(workspaceId.uuidString.prefix(8))",
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
                entityId: "timeline:\(id.uuidString.prefix(8))",
                error: error
            ))
        }

        if !degradations.isEmpty {
            logger.warning("""
            deleteTimelinePermanently: partial cleanup — timeline: \(id.uuidString.prefix(8)), \
            failures: \(degradations.count), operations: \(degradations.map(\.operation).joined(separator: ", "))
            """)
        }

        return TimelineDeletionResult(timelineId: id, degradations: degradations)
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
    /// Initializes and configures the internal components for a conversation timeline.
    func setupTimelineComponents(
        timeline: Timeline,
        workspaceURL: URL
    ) async {
        let contextWorkspace: (any Workspace)?
        if let firstId = timeline.attachedWorkspaceIds.first {
            do {
                contextWorkspace = try await workspaceResolver.getWorkspace(id: firstId)
            } catch {
                logger.warning("""
                setupTimelineComponents: context workspace resolution failed — \
                workspace: \(firstId.uuidString.prefix(8)), timeline: \(timeline.id.uuidString.prefix(8)), \
                operation: resolveContextWorkspace, error: \(ErrorKit.userFriendlyMessage(for: error))
                """)
                timelineDegradations[timeline.id, default: []].append(TurnDiagnostic(
                    dependency: .workspace,
                    operation: "resolveContextWorkspace",
                    entityId: "workspace:\(firstId.uuidString.prefix(8))",
                    errorIdentity: ChatEvent.ErrorIdentity.extracting(from: error),
                    message: ErrorKit.userFriendlyMessage(for: error)
                ))
                contextWorkspace = nil
            }
        } else {
            contextWorkspace = nil
        }

        let turnBriefingBuilder = TurnBriefingBuilder(
            workspace: contextWorkspace,
            memoryStore: memoryStore,
            embeddingService: embeddingService
        )
        turnBriefingBuilders[timeline.id] = turnBriefingBuilder

        let toolContextTimeline = ToolTimelineContext()

        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: timeline,
            jailRoot: workspaceURL.path,
            toolContextTimeline: toolContextTimeline,
            runtimeToolPolicy: runtimeToolPolicy,
            timelineStore: timelineStore,
            messageStore: messageStore
        )
        toolManagers[timeline.id] = toolManager

        for attachedId in timeline.attachedWorkspaceIds {
            do {
                if let workspace = try await workspaceResolver.getWorkspace(id: attachedId) {
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
                    entityId: "workspace:\(attachedId.uuidString.prefix(8))",
                    errorIdentity: ChatEvent.ErrorIdentity.extracting(from: error),
                    message: ErrorKit.userFriendlyMessage(for: error)
                ))
            }
        }
    }

    /// Writes the configured seed notes into a freshly created timeline workspace's `Notes/`
    /// directory (PKRR-029).
    ///
    /// Replaces the former unconditional `writeDefaultNotes(at:)` which always wrote
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
