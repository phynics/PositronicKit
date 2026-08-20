import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

/// Manages thread threads, their associated context, and tool execution environments.
///
/// `ThreadManager` is the public coordinator/cache owner for threads: it holds the
/// in-memory `threads`/`turnBriefingBuilders`/`toolManagers` caches and the
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

    /// In-memory cache of active threads.
    var threads: [UUID: Thread] = [:]

    /// Context managers responsible for RAG and context gathering for each thread.
    var turnBriefingBuilders: [UUID: TurnBriefingBuilder] = [:]

    /// Tool managers handling tool registration and availability for each thread.
    var toolManagers: [UUID: ThreadToolRegistry] = [:]

    /// Preparation degradations discovered while hydrating a thread's runtime components.
    var threadDegradations: [UUID: [TurnDiagnostic]] = [:]

    /// Monotonic liveness versions for threads. Permanent deletion advances the version before
    /// its first suspension so in-flight mutations can reject stale state before saving it.
    var threadLivenessVersions: [UUID: UInt64] = [:]

    /// Tracks deletions in progress so a new mutation cannot join after the deletion version was
    /// advanced but before persistence cleanup has finished.
    var threadsBeingPermanentlyDeleted: Set<UUID> = []

    /// Send-scoped registry of the active stream-driving task for each thread. Replaces the
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

    /// How the per-thread filesystem workspace is provisioned and owned (PKRR-029).
    ///
    /// `.noWorkspace` (the default) creates no directory, writes no notes, and persists no
    /// workspace record. `.ephemeralWorkspace` owns a self-cleaning scratch directory.
    /// `.hostManaged` preserves the pre-PKRR-029 behavior of an explicit `workspaceRoot`.
    let workspaceProfile: WorkspaceProfile

    /// The filesystem root thread workspace directories are anchored under.
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
    /// Per-thread prompt-history/journal-diff registry. When non-nil, `evictThreadFromMemory(id:)`
    /// and `cleanupStaleThreads(maxAge:)` evict the corresponding history entry alongside the
    /// in-memory caches, so deleted/stale threads don't leak journal-diff state.
    let promptHistoryRegistry: ThreadPromptJournals?

    let logger = Logger.module(named: "thread-manager")

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
        agentID: UUID?,
        message: String
    ) async -> [any Prompt] {
        let buildContext = PromptBuildContext(
            threadID: threadID,
            agentID: agentID,
            message: message
        )
        var sections: [any Prompt] = []
        for provider in sectionProviders {
            sections += await provider.sections(for: buildContext)
        }
        return sections
    }

    // MARK: - Task Management

    /// Registers a generation task for a thread, cancelling any previous active task.
    /// The `turnID` scopes the registration so a stale turn's terminal cleanup cannot evict a
    /// newer turn's entry.
    public func registerTask(_ task: Task<Void, Never>, turnID: UUID, for threadID: UUID) async {
        await taskRegistry.register(task, turnID: turnID, for: threadID)
    }

    /// Explicitly cancels an ongoing generation task for a thread. The entry is removed by
    /// the task's own terminal path.
    public func cancelGeneration(for threadID: UUID) async {
        await taskRegistry.cancelActive(for: threadID)
    }

    /// Removes the task entry on a terminal path, but only if `turnID` is still the active turn.
    /// A stale turn (superseded by a newer one) is a no-op.
    public func removeTask(turnID: UUID, for threadID: UUID) async {
        await taskRegistry.removeIfActive(turnID: turnID, for: threadID)
    }

    /// Turn-scoped cancellation: only cancels if `turnID` is still the active turn. Returns
    /// `false` for a stale turn that has been superseded.
    @discardableResult
    public func cancelGeneration(turnID: UUID, for threadID: UUID) async -> Bool {
        await taskRegistry.cancel(turnID: turnID, for: threadID)
    }

    /// Cancels any active task for the thread and awaits its termination (bounded cleanup
    /// for eviction/deletion).
    public func cancelActiveTaskAndAwait(for threadID: UUID) async {
        await taskRegistry.cancelAndAwait(for: threadID)
    }

    /// Snapshots the currently registered task without cancelling or removing it.
    /// Awaiting the returned task joins its complete terminal path, including registry cleanup.
    func activeTaskCompletion(for threadID: UUID) async -> Task<Void, Never>? {
        await taskRegistry.activeTaskCompletion(for: threadID)
    }

    /// Whether a generation task is currently registered for the thread.
    func hasActiveTask(for threadID: UUID) async -> Bool {
        await taskRegistry.hasActiveTurn(for: threadID)
    }
}

// MARK: - Queries & Agent Support

public extension ThreadManager {
    /// Pure lookup: retrieves a thread by its ID without mutating `updatedAt`.
    /// Callers that want to record activity should call ``touchThread(id:)`` explicitly.
    func thread(id: UUID) -> Thread? {
        threads[id]
    }

    /// Explicitly marks a thread as recently active by bumping its `updatedAt` timestamp.
    /// No-op if the thread isn't cached in memory.
    func touchThread(id: UUID) {
        guard var thread = threads[id] else { return }
        thread.updatedAt = Date()
        threads[id] = thread
    }

    /// Fetches the message history for a specific thread from persistence.
    func getHistory(for threadID: UUID) async throws -> [Message] {
        let threadMessages = try await messageStore.fetchMessages(for: threadID)
        return threadMessages.map { $0.toMessage() }
    }

    /// Lists all active (non-archived) threads from persistence.
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

    /// Enabled tools for an active thread (empty if the thread has no active tool manager).
    /// A pure query, not subordinate-manager access: it does not expose `ThreadToolRegistry`
    /// itself (PKV3-010), only the read a host needs to merge system tools with request-scoped
    /// ones before sending a turn.
    func enabledTools(for threadID: UUID) async -> [AnyTool] {
        guard let toolManager = toolManagers[threadID] else { return [] }
        return await toolManager.getEnabledTools()
    }

    /// Enables a tool by id on an active thread. No-op (does not throw) if the thread has
    /// no active tool manager; returns whether a tool manager was found to act on.
    @discardableResult
    func enableTool(id: String, for threadID: UUID) async -> Bool {
        guard let toolManager = toolManagers[threadID] else { return false }
        await toolManager.enableTool(id: id)
        return true
    }

    /// Disables a tool by id on an active thread. No-op (does not throw) if the thread has
    /// no active tool manager; returns whether a tool manager was found to act on.
    @discardableResult
    func disableTool(id: String, for threadID: UUID) async -> Bool {
        guard let toolManager = toolManagers[threadID] else { return false }
        await toolManager.disableTool(id: id)
        return true
    }

    func getToolSource(toolId: String, for threadID: UUID) async throws -> String? {
        guard let thread = threads[threadID] else { return nil }

        if let toolManager = toolManagers[threadID] {
            let systemTools = await toolManager.getAvailableTools()
            if systemTools.contains(where: { $0.callName == toolId }) {
                return "System"
            }
        }

        do {
            return try await toolPersistence.fetchToolSource(
                toolId: toolId,
                workspaceIds: thread.attachedWorkspaceIDs,
                primaryWorkspaceId: nil
            )
        } catch {
            logger.error("""
            getToolSource failed — toolId: \(toolId), thread: \(threadID.uuidString.prefix(8)), \
            operation: fetchToolSource, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            throw ThreadError.unavailable
        }
    }
}

// MARK: - Internal Subordinate-Manager Access (PKV3-010: not part of the public surface)

extension ThreadManager {
    /// Returns the current liveness version for a thread. A missing entry is the initial version.
    func threadLivenessVersion(for threadID: UUID) -> UInt64 {
        threadLivenessVersions[threadID] ?? 0
    }

    /// Invalidates operations that captured an earlier liveness version for the thread and marks
    /// the deletion active before its first suspension.
    func invalidateThreadLiveness(for threadID: UUID) {
        threadLivenessVersions[threadID] = (threadLivenessVersions[threadID] ?? 0) &+ 1
        threadsBeingPermanentlyDeleted.insert(threadID)
    }

    /// Closes a deletion epoch. Advancing again prevents operations that captured the in-progress
    /// version from saving after cleanup completes, while allowing a fresh retry if cleanup was
    /// partial and the persisted row remains.
    func completeThreadDeletionLiveness(for threadID: UUID) {
        threadLivenessVersions[threadID] = (threadLivenessVersions[threadID] ?? 0) &+ 1
        threadsBeingPermanentlyDeleted.remove(threadID)
    }

    /// Throws when a thread was permanently deleted after an operation captured its version.
    func requireThreadLiveness(for threadID: UUID, version: UInt64) throws {
        guard !threadsBeingPermanentlyDeleted.contains(threadID),
              threadLivenessVersion(for: threadID) == version else
        {
            throw ThreadError.threadNotFound
        }
    }

    /// Retrieves the turn briefing builder for a thread if it is active.
    func getTurnBriefingBuilder(for threadID: UUID) -> TurnBriefingBuilder? {
        return turnBriefingBuilders[threadID]
    }

    /// Retrieves the tool manager for a thread if it is active.
    func getToolManager(for threadID: UUID) -> ThreadToolRegistry? {
        return toolManagers[threadID]
    }

    func consumeDegradations(for threadID: UUID) -> [TurnDiagnostic] {
        threadDegradations.removeValue(forKey: threadID) ?? []
    }
}
