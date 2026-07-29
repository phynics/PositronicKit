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
    func createTimeline(title: String = "New Conversation") async throws -> Timeline {
        let timelineId = UUID()

        let timelineWorkspaceURL = workspaceRoot.appendingPathComponent(
            "timelines", isDirectory: true
        )
        .appendingPathComponent(timelineId.uuidString, isDirectory: true)

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
            try writeDefaultNotes(at: timelineWorkspaceURL)
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

    /// Evicts all in-memory runtime state for a timeline. This is the runtime-eviction seam;
    /// callers that also want to delete the persisted timeline must additionally call
    /// `timelineStore.deleteTimeline(id:)`.
    func deleteTimeline(id: UUID) async {
        await evictTimelineFromMemory(id: id)
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
    /// Evicts all in-memory runtime state for a timeline: the cached `Timeline`,
    /// `TurnBriefingBuilder`, `TimelineToolRegistry`, and (when a prompt-history registry
    /// was injected) the journal-diff history entry. Does not touch persistence.
    ///
    /// Active generation work is cancelled and awaited (bounded cleanup) before cache eviction
    /// so streaming/tools/persistence/plugins cannot continue against a timeline whose
    /// in-memory state has already been torn down.
    ///
    /// This is the in-memory-only phase shared by `deleteTimeline(id:)` and
    /// `cleanupStaleTimelines(maxAge:)`.
    func evictTimelineFromMemory(id: UUID) async {
        await cancelActiveTaskAndAwait(for: id)
        timelines.removeValue(forKey: id)
        turnBriefingBuilders.removeValue(forKey: id)
        toolManagers.removeValue(forKey: id)
        await promptHistoryRegistry?.removeHistory(for: id)
    }

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
            }
        }
    }

    /// Writes the default `Notes/Welcome.md` and `Notes/Project.md` files into a freshly created
    /// timeline workspace.
    func writeDefaultNotes(at workspaceURL: URL) throws {
        let notesDir = workspaceURL.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        let welcomeNote = """
        # Welcome to Your PositronicKit Timeline

        This timeline is your private workspace. You can use the `Notes/` directory \
        in the Primary Workspace to store information that should persist and influence \
        your behavior across turns.

        ## System Orientation
        - Primary Workspace: Your runtime-managed sandbox.
        - Attached Workspaces: Directories mapped during this timeline.
        - Context Depth: Use the `Notes/` directory for long-term facts and project-specific guidance.
        """
        try welcomeNote.write(
            to: notesDir.appendingPathComponent("Welcome.md"),
            atomically: true, encoding: .utf8
        )

        let projectNote = """
        # Project Goals & Progress

        Use this note to track the active objective and your current progress.

        ## Active Objective
        [Describe what the user wants to achieve here]

        ## Key Milestones
        - [ ] Milestone 1
        - [ ] Milestone 2

        ## Decisions & Context
        Record any critical decisions made during the timeline here.
        """
        try projectNote.write(
            to: notesDir.appendingPathComponent("Project.md"),
            atomically: true, encoding: .utf8
        )
    }
}
