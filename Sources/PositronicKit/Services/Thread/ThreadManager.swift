import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

/// Controls which built-in runtime tools are installed for each Thread.
///
/// This is a facade configuration value. The cache-owning coordinator that applies
/// it is intentionally not part of the consumer-facing entry point.
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

/// Internal coordinator/cache owner for Threads and their execution environments.
actor ThreadManager {
    struct Stores {
        let threadStore: any ThreadPersistenceProtocol
        let messageStore: any ThreadMessageStoreProtocol
        let workspaceStore: any WorkspaceStore
        let workspaceBindingRepository: any WorkspaceBindingRepository
        let runtimeRepository: any ThreadRuntimeRepository
        let toolPersistence: any ToolPersistenceProtocol

        // The binding repository is resolved exactly once, by `PersistenceConfiguration`
        // (ADR 0004: binding authority is repository-only). This seam receives it rather than
        // re-deriving it from an `as?` downcast of `workspaceStore` (C-02) — every caller must
        // pass one explicitly.
        init(
            threadStore: any ThreadPersistenceProtocol,
            messageStore: any ThreadMessageStoreProtocol,
            workspaceStore: any WorkspaceStore,
            workspaceBindingRepository: any WorkspaceBindingRepository,
            runtimeRepository: any ThreadRuntimeRepository,
            toolPersistence: any ToolPersistenceProtocol
        ) {
            self.threadStore = threadStore
            self.messageStore = messageStore
            self.workspaceStore = workspaceStore
            self.workspaceBindingRepository = workspaceBindingRepository
            self.runtimeRepository = runtimeRepository
            self.toolPersistence = toolPersistence
        }
    }

    // MARK: - State

    /// In-memory cache of active threads.
    var threads: [UUID: Thread] = [:]

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
    /// Process-local FIFO lanes for ordinary Workspace execution.
    let workspaceExecutionCoordinator: WorkspaceExecutionCoordinator
    /// Shared per-Thread lane for Turn admission and authority mutations.
    let threadAuthorityCoordinator: ThreadAuthorityCoordinator

    // MARK: - Dependencies

    let threadStore: any ThreadPersistenceProtocol
    let messageStore: any ThreadMessageStoreProtocol
    let workspaceStore: any WorkspaceStore
    let workspaceBindingRepository: any WorkspaceBindingRepository
    let runtimeRepository: any ThreadRuntimeRepository
    let toolPersistence: any ToolPersistenceProtocol

    /// Persists a workspace reference into the store this manager validates,
    /// so an import followed by `attachWorkspace(_:to:)` succeeds.
    ///
    /// Hosts that construct their runtime through the `PositronicKit` facade
    /// (whose stores are not injectable) use this to import advertised
    /// workspace references; it runs on the actor, so it is Sendable-safe.
    func importWorkspace(_ reference: WorkspaceReference) async throws {
        try await workspaceStore.saveWorkspace(reference)
    }

    /// How the per-thread filesystem workspace is provisioned and owned (PKRR-029).
    ///
    /// `.noWorkspace` (the default) creates no directory, writes no notes, and persists no
    /// workspace record. `.ephemeralWorkspace` owns a self-cleaning scratch directory.
    /// `.hostManaged` uses a host-owned directory selected by the caller.
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
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        promptHistoryRegistry: ThreadPromptJournals? = nil,
        taskRegistry: ThreadTaskRegistry? = nil,
        workspaceExecutionCoordinator: WorkspaceExecutionCoordinator? = nil,
        threadAuthorityCoordinator: ThreadAuthorityCoordinator? = nil
    ) {
        threadStore = stores.threadStore
        messageStore = stores.messageStore
        workspaceStore = stores.workspaceStore
        workspaceBindingRepository = stores.workspaceBindingRepository
        runtimeRepository = stores.runtimeRepository
        toolPersistence = stores.toolPersistence
        self.workspaceProfile = workspaceProfile
        self.runtimeToolPolicy = runtimeToolPolicy
        self.promptHistoryRegistry = promptHistoryRegistry
        self.taskRegistry = taskRegistry ?? ThreadTaskRegistry()
        self.workspaceExecutionCoordinator = workspaceExecutionCoordinator ?? WorkspaceExecutionCoordinator()
        self.threadAuthorityCoordinator = threadAuthorityCoordinator ?? ThreadAuthorityCoordinator()
        workspaceResolver = resolver
    }

    // MARK: - Task Management

    /// Registers a generation task for a thread, cancelling any previous active task.
    /// The `turnID` scopes the registration so a stale turn's terminal cleanup cannot evict a
    /// newer turn's entry.
    @discardableResult
    func registerTask(_ task: Task<Void, Never>, turnID: UUID, for threadID: UUID) async -> Bool {
        await taskRegistry.register(task, turnID: turnID, for: threadID)
    }

    /// Explicitly cancels an ongoing generation task for a thread. The entry is removed by
    /// the task's own terminal path.
    func cancelGeneration(for threadID: UUID) async {
        await taskRegistry.cancelActive(for: threadID)
    }

    /// Removes the task entry on a terminal path, but only if `turnID` is still the active turn.
    /// A stale turn (superseded by a newer one) is a no-op.
    func removeTask(turnID: UUID, for threadID: UUID) async {
        await taskRegistry.removeIfActive(turnID: turnID, for: threadID)
    }

    /// Turn-scoped cancellation: only cancels if `turnID` is still the active turn. Returns
    /// `false` for a stale turn that has been superseded.
    @discardableResult
    func cancelGeneration(turnID: UUID, for threadID: UUID) async -> Bool {
        await taskRegistry.cancel(turnID: turnID, for: threadID)
    }

    /// Cancels any active task for the thread and awaits its termination (bounded cleanup
    /// for eviction/deletion).
    func cancelActiveTaskAndAwait(for threadID: UUID) async {
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

    /// Rejects authority-changing operations while a Turn still owns this Thread's execution
    /// context. Reads remain available. The durable repository is authoritative.
    func requireExecutionContextMutable(for threadID: UUID) async throws {
        if let active = try await runtimeRepository.fetchActiveTurn(for: threadID) {
            throw ThreadRuntimeRepositoryError.threadBusy(
                threadID: threadID,
                activeTurnID: active.identity.turnID
            )
        }
    }

    /// Revalidates the durable Workspace binding immediately before tool execution.
    func requireWorkspaceBinding(_ workspaceID: UUID, for threadID: UUID) async throws {
        if let owner = try await workspaceBindingRepository.threadID(for: workspaceID) {
            guard owner == threadID else {
                throw WorkspaceBindingRepositoryError.workspaceAlreadyBound(
                    workspaceID: workspaceID,
                    threadID: owner
                )
            }
            return
        }
        // A missing repository row is a hard denial.
        throw WorkspaceBindingRepositoryError.bindingNotFound(
            workspaceID: workspaceID,
            threadID: threadID
        )
    }

    /// Executes work under the process-local FIFO lane for an ordinary Workspace.
    func withWorkspaceExecution<T: Sendable>(
        _ workspaceID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await workspaceExecutionCoordinator.withWorkspaceExecution(workspaceID: workspaceID, operation: operation)
    }

    /// Serializes Turn admission and Thread authority mutations under one per-Thread lane.
    func withThreadAuthority<T: Sendable>(
        _ threadID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await threadAuthorityCoordinator.withThread(threadID, operation: operation)
    }
}

// MARK: - Queries & Agent Support

extension ThreadManager {
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

    /// Keeps the coordinator's compatibility cache aligned after Agent attachment mutations
    /// commit through the shared Thread store.
    func replaceCachedThreadIfPresent(_ thread: Thread) {
        guard threads[thread.id] != nil else { return }
        threads[thread.id] = thread
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

extension ThreadManager {
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
        guard threads[threadID] != nil else { return nil }

        if let toolManager = toolManagers[threadID] {
            let systemTools = await toolManager.getAvailableTools()
            if systemTools.contains(where: { $0.callName == toolId }) {
                return "System"
            }
        }

        do {
            let workspaceIDs = try await workspaceBindingRepository
                .bindings(for: threadID)
                .map(\.workspaceID)
            return try await toolPersistence.fetchToolSource(
                toolId: toolId,
                workspaceIds: workspaceIDs,
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
              threadLivenessVersion(for: threadID) == version
        else {
            throw ThreadError.threadNotFound
        }
    }

    /// Retrieves the tool manager for a thread if it is active.
    func getToolManager(for threadID: UUID) -> ThreadToolRegistry? {
        return toolManagers[threadID]
    }

    func consumeDegradations(for threadID: UUID) -> [TurnDiagnostic] {
        threadDegradations.removeValue(forKey: threadID) ?? []
    }
}
