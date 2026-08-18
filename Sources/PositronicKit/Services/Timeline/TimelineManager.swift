import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared
import PKUtilities

/// Manages conversation timelines, their associated context, and tool execution environments.
///
/// `ThreadManager` is the public coordinator/cache owner for timelines: it holds the
/// in-memory `timelines`/`turnBriefingBuilders`/`toolManagers` caches and the
/// `taskRegistry` (send-scoped active-task tracking), and manages lifecycle,
/// workspace-attachment, and tool-policy behavior. Concrete workspace behavior
/// remains behind `WorkspaceResolver` / `WorkspaceFactory` / `Workspace` so hosts can
/// supply local or remote workspace implementations without changing core orchestration.
public actor ThreadManager {
    public struct RuntimeToolPolicy: Sendable, Equatable {
        public let installFilesystemTools: Bool
        public let installThreadObservationTools: Bool
        public let installThreadSendTool: Bool

        public init(
            installFilesystemTools: Bool = true,
            installThreadObservationTools: Bool = true,
            installThreadSendTool: Bool = true
        ) {
            self.installFilesystemTools = installFilesystemTools
            self.installThreadObservationTools = installThreadObservationTools
            self.installThreadSendTool = installThreadSendTool
        }

        public static let `default` = RuntimeToolPolicy()
        public static let denyAll = RuntimeToolPolicy(
            installFilesystemTools: false,
            installThreadObservationTools: false,
            installThreadSendTool: false
        )
    }

    public struct Stores: Sendable {
        public let threadStore: any ThreadPersistenceProtocol
        public let messageStore: any ThreadMessageStoreProtocol
        public let workspaceStore: any WorkspaceStore
        public let toolPersistence: any ToolPersistenceProtocol
        public let memoryStore: any MemoryStoreProtocol

        public init(
            threadStore: any ThreadPersistenceProtocol,
            messageStore: any ThreadMessageStoreProtocol,
            workspaceStore: any WorkspaceStore,
            toolPersistence: any ToolPersistenceProtocol,
            memoryStore: any MemoryStoreProtocol = InMemoryMemoryStore()
        ) {
            self.threadStore = threadStore
            self.messageStore = messageStore
            self.workspaceStore = workspaceStore
            self.toolPersistence = toolPersistence
            self.memoryStore = memoryStore
        }
    }

    // MARK: - State

    /// In-memory cache of active timelines.
    var timelines: [UUID: Thread] = [:]

    /// Context managers responsible for RAG and context gathering for each timeline.
    var turnBriefingBuilders: [UUID: TurnBriefingBuilder] = [:]

    /// Tool managers handling tool registration and availability for each timeline.
    var toolManagers: [UUID: ThreadToolRegistry] = [:]

    /// Preparation degradations discovered while hydrating a timeline's runtime components.
    var timelineDegradations: [UUID: [TurnDiagnostic]] = [:]

    /// Monotonic liveness versions for timelines. Permanent deletion advances the version before
    /// its first suspension so in-flight mutations can reject stale state before saving it.
    var timelineLivenessVersions: [UUID: UInt64] = [:]

    /// Tracks deletions in progress so a new mutation cannot join after the deletion version was
    /// advanced but before persistence cleanup has finished.
    var timelinesBeingPermanentlyDeleted: Set<UUID> = []

    /// Send-scoped registry of the active stream-driving task for each timeline. Replaces the
    /// former `activeTasks` dict so cancellation is send-scoped (a stale send cannot evict or
    /// cancel a newer one) and eviction/deletion can await bounded cleanup.
    let taskRegistry: ThreadTaskRegistry

    // MARK: - Dependencies

    let threadStore: any ThreadPersistenceProtocol
    let messageStore: any ThreadMessageStoreProtocol
    let workspaceStore: any WorkspaceStore
    let toolPersistence: any ToolPersistenceProtocol
    let memoryStore: any MemoryStoreProtocol
    let embeddingService: any EmbeddingServiceProtocol

    /// Persists a workspace reference into the store this manager validates,
    /// so an import followed by `attachWorkspace(_:to:)` succeeds.
    ///
    /// Hosts that construct their runtime through the `PositronicKit` facade
    /// (whose stores are not injectable) use this to import advertised
    /// workspace references; it runs on the actor, so it is Sendable-safe.
    public func importWorkspace(_ reference: WorkspaceReference) async throws {
        try await workspaceStore.saveWorkspace(reference)
    }

    /// How the per-timeline filesystem workspace is provisioned and owned (PKRR-029).
    ///
    /// `.noWorkspace` (the default) creates no directory, writes no notes, and persists no
    /// workspace record. `.ephemeralWorkspace` owns a self-cleaning scratch directory.
    /// `.hostManaged` preserves the pre-PKRR-029 behavior of an explicit `workspaceRoot`.
    let workspaceProfile: WorkspaceProfile

    /// The filesystem root timeline workspace directories are anchored under.
    ///
    /// Derived from ``workspaceProfile``. For `.noWorkspace` this is a process-temporary path
    /// used only to compute tool-manager jail roots; no directory is created. Prefer reading
    /// ``workspaceProfile`` directly for lifecycle decisions.
    var workspaceRoot: URL {
        workspaceProfile.catalogRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("positronickit-workspaces", isDirectory: true)
    }

    /// Not `public` (PKV3-010): resolution internals stay behind the lifecycle/attachment/query
    /// surface. Hosts that need custom workspace behavior inject a `WorkspaceResolver` at
    /// construction; they don't reach back through `ThreadManager` to get one.
    let workspaceResolver: any WorkspaceResolver
    let sectionProviders: [any PromptSectionProviding]
    let runtimeToolPolicy: RuntimeToolPolicy
    /// Per-timeline prompt-history/journal-diff registry. When non-nil, `evictThreadFromMemory(id:)`
    /// and `cleanupStaleThreads(maxAge:)` evict the corresponding history entry alongside the
    /// in-memory caches, so deleted/stale timelines don't leak journal-diff state.
    let promptHistoryRegistry: ThreadPromptJournals?

    let logger = Logger.module(named: "timeline-manager")

    // MARK: - Initialization

    /// Designated initializer: accepts a fully-formed `any WorkspaceResolver` directly.
    ///
    /// `ThreadManager` does not know how to assemble the default catalog/factory/resolver
    /// stack; that composition lives in `WorkspaceResolverFactory` (and, for the top-level
    /// facade's default behavior, in `PositronicKit.Configuration`). Hosts that want the
    /// bundled local-filesystem default can build one via `WorkspaceResolverFactory.makeDefault`
    /// or use the `workspaceCreator:`-based convenience initializer below.
    ///
    /// Not `public`: `promptHistoryRegistry`'s type (`ThreadPromptJournals`) is
    /// package-internal, so this initializer can't be exposed with that parameter present.
    /// Same-module callers (the facade) use it directly; public callers use the overload below.
    init(
        stores: Stores,
        workspaceProfile: WorkspaceProfile,
        resolver: any WorkspaceResolver,
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        promptHistoryRegistry: ThreadPromptJournals? = nil,
        taskRegistry: ThreadTaskRegistry? = nil
    ) {
        threadStore = stores.threadStore
        messageStore = stores.messageStore
        workspaceStore = stores.workspaceStore
        toolPersistence = stores.toolPersistence
        memoryStore = stores.memoryStore
        self.embeddingService = embeddingService
        self.workspaceProfile = workspaceProfile
        self.sectionProviders = sectionProviders
        self.runtimeToolPolicy = runtimeToolPolicy
        self.promptHistoryRegistry = promptHistoryRegistry
        self.taskRegistry = taskRegistry ?? ThreadTaskRegistry()
        workspaceResolver = resolver
    }

    // MARK: - Prompt & Extension Support

    /// Gathers additional prompt sections from all registered `PromptSectionProviding` instances.
    public func gatherExtensionSections(
        threadID: UUID,
        agentInstanceID: UUID?,
        message: String
    ) async -> [any Prompt] {
        let buildContext = PromptBuildContext(
            threadID: threadID,
            agentInstanceID: agentInstanceID,
            message: message
        )
        var sections: [any Prompt] = []
        for provider in sectionProviders {
            sections += await provider.sections(for: buildContext)
        }
        return sections
    }

    // MARK: - Task Management

    /// Registers a generation task for a timeline, cancelling any previous active task.
    /// The `sendID` scopes the registration so a stale send's terminal cleanup cannot evict a
    /// newer send's entry.
    public func registerTask(_ task: Task<Void, Never>, sendID: UUID, for threadID: UUID) async {
        await taskRegistry.register(task, sendID: sendID, for: threadID)
    }

    /// Explicitly cancels an ongoing generation task for a timeline. The entry is removed by
    /// the task's own terminal path.
    public func cancelGeneration(for threadID: UUID) async {
        await taskRegistry.cancelActive(for: threadID)
    }

    /// Removes the task entry on a terminal path, but only if `sendID` is still the active send.
    /// A stale send (superseded by a newer one) is a no-op.
    public func removeTask(sendID: UUID, for threadID: UUID) async {
        await taskRegistry.removeIfActive(sendID: sendID, for: threadID)
    }

    /// Send-scoped cancellation: only cancels if `sendID` is still the active send. Returns
    /// `false` for a stale send that has been superseded.
    @discardableResult
    public func cancelGeneration(sendID: UUID, for threadID: UUID) async -> Bool {
        await taskRegistry.cancel(sendID: sendID, for: threadID)
    }

    /// Cancels any active task for the timeline and awaits its termination (bounded cleanup
    /// for eviction/deletion).
    public func cancelActiveTaskAndAwait(for threadID: UUID) async {
        await taskRegistry.cancelAndAwait(for: threadID)
    }

    /// Snapshots the currently registered task without cancelling or removing it.
    /// Awaiting the returned task joins its complete terminal path, including registry cleanup.
    func activeTaskCompletion(for threadID: UUID) async -> Task<Void, Never>? {
        await taskRegistry.activeTaskCompletion(for: threadID)
    }

    /// Whether a generation task is currently registered for the timeline.
    func hasActiveTask(for threadID: UUID) async -> Bool {
        await taskRegistry.hasActiveSend(for: threadID)
    }
}

// MARK: - Queries & Agent Support

public extension ThreadManager {
    /// Pure lookup: retrieves a timeline by its ID without mutating `updatedAt`.
    /// Callers that want to record activity should call ``touchTimeline(id:)`` explicitly.
    func thread(id: UUID) -> Thread? {
        timelines[id]
    }

    /// Explicitly marks a timeline as recently active by bumping its `updatedAt` timestamp.
    /// No-op if the timeline isn't cached in memory.
    func touchThread(id: UUID) {
        guard var timeline = timelines[id] else { return }
        timeline.updatedAt = Date()
        timelines[id] = timeline
    }

    /// Fetches the message history for a specific timeline from persistence.
    func getHistory(for threadID: UUID) async throws -> [Message] {
        let conversationMessages = try await messageStore.fetchMessages(for: threadID)
        return conversationMessages.map { $0.toMessage() }
    }

    /// Lists all active (non-archived) timelines from persistence.
    func listThreads() async throws -> [Thread] {
        return try await threadStore.fetchAllThreads(includeArchived: false)
    }
}

// MARK: - Tool Management

public extension ThreadManager {
    func findWorkspaceForTool(_ tool: ToolReference, in workspaceIds: [UUID]) async throws
        -> UUID?
    {
        return try await toolPersistence.findWorkspaceId(forToolId: tool.toolID, in: workspaceIds)
    }

    /// Enabled tools for an active timeline (empty if the timeline has no active tool manager).
    /// A pure query, not subordinate-manager access: it does not expose `ThreadToolRegistry`
    /// itself (PKV3-010), only the read a host needs to merge system tools with request-scoped
    /// ones before sending a turn.
    func enabledTools(for threadID: UUID) async -> [AnyTool] {
        guard let toolManager = toolManagers[threadID] else { return [] }
        return await toolManager.getEnabledTools()
    }

    /// Enables a tool by id on an active timeline. No-op (does not throw) if the timeline has
    /// no active tool manager; returns whether a tool manager was found to act on.
    @discardableResult
    func enableTool(id: String, for threadID: UUID) async -> Bool {
        guard let toolManager = toolManagers[threadID] else { return false }
        await toolManager.enableTool(id: id)
        return true
    }

    /// Disables a tool by id on an active timeline. No-op (does not throw) if the timeline has
    /// no active tool manager; returns whether a tool manager was found to act on.
    @discardableResult
    func disableTool(id: String, for threadID: UUID) async -> Bool {
        guard let toolManager = toolManagers[threadID] else { return false }
        await toolManager.disableTool(id: id)
        return true
    }

    func getToolSource(toolId: String, for threadID: UUID) async throws -> String? {
        guard let timeline = timelines[threadID] else { return nil }

        if let toolManager = toolManagers[threadID] {
            let systemTools = await toolManager.getAvailableTools()
            if systemTools.contains(where: { $0.callName == toolId }) {
                return "System"
            }
        }

        do {
            return try await toolPersistence.fetchToolSource(
                toolId: toolId,
                workspaceIds: timeline.attachedWorkspaceIDs,
                primaryWorkspaceId: nil
            )
        } catch {
            logger.error("""
            getToolSource failed — toolId: \(toolId), timeline: \(threadID.uuidString.prefix(8)), \
            operation: fetchToolSource, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            throw ThreadError.unavailable
        }
    }
}

// MARK: - Internal Subordinate-Manager Access (PKV3-010: not part of the public surface)

extension ThreadManager {
    /// Returns the current liveness version for a timeline. A missing entry is the initial version.
    func threadLivenessVersion(for threadID: UUID) -> UInt64 {
        timelineLivenessVersions[threadID] ?? 0
    }

    /// Invalidates operations that captured an earlier liveness version for the timeline and marks
    /// the deletion active before its first suspension.
    func invalidateThreadLiveness(for threadID: UUID) {
        timelineLivenessVersions[threadID] = (timelineLivenessVersions[threadID] ?? 0) &+ 1
        timelinesBeingPermanentlyDeleted.insert(threadID)
    }

    /// Closes a deletion epoch. Advancing again prevents operations that captured the in-progress
    /// version from saving after cleanup completes, while allowing a fresh retry if cleanup was
    /// partial and the persisted row remains.
    func completeThreadDeletionLiveness(for threadID: UUID) {
        timelineLivenessVersions[threadID] = (timelineLivenessVersions[threadID] ?? 0) &+ 1
        timelinesBeingPermanentlyDeleted.remove(threadID)
    }

    /// Throws when a timeline was permanently deleted after an operation captured its version.
    func requireThreadLiveness(for threadID: UUID, version: UInt64) throws {
        guard !timelinesBeingPermanentlyDeleted.contains(threadID),
              threadLivenessVersion(for: threadID) == version else
        {
            throw ThreadError.threadNotFound
        }
    }

    /// Retrieves the turn briefing builder for a timeline if it is active.
    func getTurnBriefingBuilder(for threadID: UUID) -> TurnBriefingBuilder? {
        return turnBriefingBuilders[threadID]
    }

    /// Retrieves the tool manager for a timeline if it is active.
    func getToolManager(for threadID: UUID) -> ThreadToolRegistry? {
        return toolManagers[threadID]
    }

    func consumeDegradations(for threadID: UUID) -> [TurnDiagnostic] {
        timelineDegradations.removeValue(forKey: threadID) ?? []
    }
}
