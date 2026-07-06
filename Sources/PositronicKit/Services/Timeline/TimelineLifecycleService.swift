import ErrorKit
import Foundation
import PKShared

/// Owns the lifecycle of in-memory timelines — creation, hydration from persistence, title
/// updates, deletion, and stale-timeline cleanup — plus the per-timeline component setup
/// (context manager, tool manager, and workspace-tool registration) that runs alongside
/// `createTimeline`/`hydrateTimeline`.
///
/// Extracted from `TimelineManager` (PKARCH-003). The service is stateless aside from the
/// injected persistence stores and a ``TimelineCache`` seam; the caches themselves stay owned
/// by `TimelineManager`, which forwards its public lifecycle methods here.
package struct TimelineLifecycleService: Sendable {
    package let cache: any TimelineCache
    package let timelineStore: any TimelinePersistenceProtocol
    package let messageStore: any MessageStoreProtocol
    package let workspaceStore: any WorkspacePersistenceProtocol
    package let workspaceManager: any WorkspaceManagerProtocol
    package let memoryStore: any MemoryStoreProtocol
    package let embeddingService: any EmbeddingServiceProtocol
    package let workspaceRoot: URL
    package let promptHistoryRegistry: TimelinePromptHistoryRegistry?
    package let runtimeToolPolicy: TimelineManager.RuntimeToolPolicy

    package init(
        cache: any TimelineCache,
        timelineStore: any TimelinePersistenceProtocol,
        messageStore: any MessageStoreProtocol,
        workspaceStore: any WorkspacePersistenceProtocol,
        workspaceManager: any WorkspaceManagerProtocol,
        memoryStore: any MemoryStoreProtocol,
        embeddingService: any EmbeddingServiceProtocol,
        workspaceRoot: URL,
        promptHistoryRegistry: TimelinePromptHistoryRegistry?,
        runtimeToolPolicy: TimelineManager.RuntimeToolPolicy
    ) {
        self.cache = cache
        self.timelineStore = timelineStore
        self.messageStore = messageStore
        self.workspaceStore = workspaceStore
        self.workspaceManager = workspaceManager
        self.memoryStore = memoryStore
        self.embeddingService = embeddingService
        self.workspaceRoot = workspaceRoot
        self.promptHistoryRegistry = promptHistoryRegistry
        self.runtimeToolPolicy = runtimeToolPolicy
    }

    // MARK: - Lifecycle

    /// Creates a new conversation timeline, initializes its workspace, and saves it to persistence.
    package func createTimeline(title: String = "New Conversation") async throws -> Timeline {
        let timelineId = UUID()

        let timelineWorkspaceURL = workspaceRoot.appendingPathComponent(
            "timelines", isDirectory: true
        )
        .appendingPathComponent(timelineId.uuidString, isDirectory: true)

        try FileManager.default.createDirectory(
            at: timelineWorkspaceURL, withIntermediateDirectories: true
        )

        try writeDefaultNotes(at: timelineWorkspaceURL)

        let workspace = WorkspaceReference(
            uri: .timelineWorkspace(timelineId),
            location: .runtime,
            rootPath: timelineWorkspaceURL.path,
            trustLevel: .full
        )

        try await workspaceStore.saveWorkspace(workspace)

        var timeline = Timeline(
            id: timelineId,
            title: title,
            attachedWorkspaceIds: [workspace.id]
        )
        timeline.workingDirectory = timelineWorkspaceURL.path

        await cache.cacheSetTimeline(timeline)
        await setupTimelineComponents(timeline: timeline, workspaceURL: timelineWorkspaceURL)
        try await timelineStore.saveTimeline(timeline)

        return timeline
    }

    /// Reconstructs a timeline and its components from persistence.
    package func hydrateTimeline(id: UUID) async throws {
        if await cache.cacheHasToolManager(for: id) { return }

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

        await cache.cacheSetTimeline(timeline)
        await setupTimelineComponents(
            timeline: timeline,
            workspaceURL: timelineWorkspaceURL
        )
    }

    /// Updates the title of a specific timeline.
    package func updateTimelineTitle(id: UUID, title: String) async throws {
        var timeline: Timeline
        if let memoryTimeline = await cache.cacheReadTimeline(id: id) {
            timeline = memoryTimeline
        } else if let dbTimeline = try? await timelineStore.fetchTimeline(id: id) {
            timeline = dbTimeline
        } else {
            throw TimelineError.timelineNotFound
        }

        timeline.title = title
        timeline.updatedAt = Date()

        await cache.cacheReplaceTimelineIfPresent(timeline)
        try await timelineStore.saveTimeline(timeline)
    }

    /// Evicts all in-memory runtime state for a timeline. This is the runtime-eviction seam;
    /// callers that also want to delete the persisted timeline must additionally call
    /// `timelineStore.deleteTimeline(id:)`.
    package func deleteTimeline(id: UUID) async {
        await evictTimelineFromMemory(id: id)
    }

    /// Removes active timelines from memory that have not been updated within the specified
    /// interval. Evicts in-memory state only; persisted timelines are unaffected. Also drops
    /// the corresponding prompt-history entries when a registry was injected.
    package func cleanupStaleTimelines(maxAge: TimeInterval) async {
        let now = Date()
        let staleIds = (await cache.cacheAllTimelineValues()).filter { timeline in
            now.timeIntervalSince(timeline.updatedAt) > maxAge
        }.map { $0.id }

        for id in staleIds {
            await evictTimelineFromMemory(id: id)
        }
    }

    /// Evicts all in-memory runtime state for a timeline: the cached `Timeline`,
    /// `ContextManager`, `TimelineToolManager`, and (when a prompt-history registry
    /// was injected) the journal-diff history entry. Does not touch persistence.
    ///
    /// This is the in-memory-only phase shared by `deleteTimeline(id:)` and
    /// `cleanupStaleTimelines(maxAge:)`; the atomic cache mutation is delegated to
    /// `TimelineCache.cacheEvictAll(id:)`.
    package func evictTimelineFromMemory(id: UUID) async {
        await cache.cacheEvictAll(id: id)
    }

    // MARK: - Component Setup

    /// Initializes and configures the internal components for a conversation timeline.
    private func setupTimelineComponents(
        timeline: Timeline,
        workspaceURL: URL
    ) async {
        let contextWorkspace: (any WorkspaceProtocol)?
        if let firstId = timeline.attachedWorkspaceIds.first {
            contextWorkspace = try? await workspaceManager.getWorkspace(id: firstId)
        } else {
            contextWorkspace = nil
        }

        let contextManager = ContextManager(
            workspace: contextWorkspace,
            memoryStore: memoryStore,
            embeddingService: embeddingService
        )
        await cache.cacheSetContextManager(contextManager, for: timeline.id)

        let toolContextTimeline = ToolTimelineContext()

        let toolManager = RuntimeToolPolicyFactory.createToolManager(
            for: timeline,
            jailRoot: workspaceURL.path,
            toolContextTimeline: toolContextTimeline,
            runtimeToolPolicy: runtimeToolPolicy,
            timelineStore: timelineStore,
            messageStore: messageStore
        )
        await cache.cacheSetToolManager(toolManager, for: timeline.id)

        for attachedId in timeline.attachedWorkspaceIds {
            if let workspace = try? await workspaceManager.getWorkspace(id: attachedId) {
                await toolManager.registerWorkspace(workspace)
            }
        }
    }

    // MARK: - Default Notes

    /// Writes the default `Notes/Welcome.md` and `Notes/Project.md` files into a freshly created
    /// timeline workspace.
    package func writeDefaultNotes(at workspaceURL: URL) throws {
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