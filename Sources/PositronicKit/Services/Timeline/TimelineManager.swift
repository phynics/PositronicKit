import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

/// Controls which built-in runtime tools are installed for each Timeline.
///
/// This is a facade configuration value. The cache-owning coordinator that applies
/// it is intentionally not part of the consumer-facing entry point.
public struct RuntimeToolPolicy: Sendable, Equatable {
    public let installFilesystemTools: Bool
    public let installTimelineObservationTools: Bool
    public let installsTimelineSendTool: Bool

    public init(
        installFilesystemTools: Bool = true,
        installTimelineObservationTools: Bool = true,
        installsTimelineSendTool: Bool = true
    ) {
        self.installFilesystemTools = installFilesystemTools
        self.installTimelineObservationTools = installTimelineObservationTools
        self.installsTimelineSendTool = installsTimelineSendTool
    }

    public static let `default` = RuntimeToolPolicy()
    public static let denyAll = RuntimeToolPolicy(
        installFilesystemTools: false,
        installTimelineObservationTools: false,
        installsTimelineSendTool: false
    )
}

/// Internal coordinator/cache owner for Timelines and their execution environments.
actor TimelineManager {
    struct Stores {
        let timelineStore: any TimelinePersistenceProtocol
        let messageStore: any TimelineMessageStoreProtocol
        let workspaceStore: any WorkspaceStore
        let workspaceBindingRepository: any WorkspaceBindingRepository
        let runtimeRepository: any TimelineRuntimeRepository
        let toolPersistence: any ToolPersistenceProtocol

        // The binding repository is resolved exactly once, by `PersistenceConfiguration`
        // (ADR 0004: binding authority is repository-only). This seam receives it rather than
        // re-deriving it from an `as?` downcast of `workspaceStore` (C-02) — every caller must
        // pass one explicitly.
        init(
            timelineStore: any TimelinePersistenceProtocol,
            messageStore: any TimelineMessageStoreProtocol,
            workspaceStore: any WorkspaceStore,
            workspaceBindingRepository: any WorkspaceBindingRepository,
            runtimeRepository: any TimelineRuntimeRepository,
            toolPersistence: any ToolPersistenceProtocol
        ) {
            self.timelineStore = timelineStore
            self.messageStore = messageStore
            self.workspaceStore = workspaceStore
            self.workspaceBindingRepository = workspaceBindingRepository
            self.runtimeRepository = runtimeRepository
            self.toolPersistence = toolPersistence
        }
    }

    // MARK: - State

    /// In-memory cache of active timelines.
    var timelines: [UUID: TimelineRecord] = [:]

    /// PKTool managers handling tool registration and availability for each timeline.
    var toolManagers: [UUID: TimelineToolRegistry] = [:]

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
    let taskRegistry: TimelineTaskRegistry
    /// Process-local FIFO lanes for ordinary Workspace execution.
    let workspaceExecutionCoordinator: WorkspaceExecutionCoordinator
    /// Shared per-Timeline lane for Turn admission and authority mutations.
    let timelineAuthorityCoordinator: TimelineAuthorityCoordinator

    // MARK: - Dependencies

    let timelineStore: any TimelinePersistenceProtocol
    let messageStore: any TimelineMessageStoreProtocol
    let workspaceStore: any WorkspaceStore
    let workspaceBindingRepository: any WorkspaceBindingRepository
    let runtimeRepository: any TimelineRuntimeRepository
    let toolPersistence: any ToolPersistenceProtocol

    /// Persists a workspace reference into the store this manager validates,
    /// so an import followed by `attachWorkspace(_:to:)` succeeds.
    ///
    /// Package-internal, and reachable only from tests: the facade creates workspaces through
    /// ``WorkspaceCapability``, so this serves test arrangements that need a store row before
    /// attachment.
    func importWorkspace(_ reference: WorkspaceReference) async throws {
        try await workspaceStore.saveWorkspace(reference)
    }

    /// How the per-timeline filesystem workspace is provisioned and owned (PKRR-029).
    ///
    /// `.noWorkspace` (the default) creates no directory, writes no notes, and persists no
    /// workspace record. `.ephemeralWorkspace` owns a self-cleaning scratch directory.
    /// `.hostManaged` uses a host-owned directory selected by the caller.
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
    /// construction; they don't reach back through `TimelineManager` to get one.
    let workspaceResolver: any WorkspaceResolver
    let runtimeToolPolicy: RuntimeToolPolicy
    /// Per-timeline prompt-history/journal-diff registry. When non-nil, `evictTimelineFromMemory(id:)`
    /// and `cleanupStaleTimelines(maxAge:)` evict the corresponding history entry alongside the
    /// in-memory caches, so deleted/stale timelines don't leak journal-diff state.
    let promptHistoryRegistry: TimelinePromptJournals?

    /// The runtime-owned terminal-commit executor. When present, hydration classifies an active
    /// Turn this process does not own so an orphan is interrupted on load rather than only at the
    /// next admission (ADR 0010). `nil` disables that load-time pass (direct-engine tests).
    let finalizer: TurnFinalizer?

    let logger = Logger.module(named: "timeline-manager")

    // MARK: - Initialization

    /// Designated initializer: accepts a fully-formed `any WorkspaceResolver` directly.
    ///
    /// `TimelineManager` does not know how to assemble the default catalog/factory/resolver
    /// stack; that composition lives in `WorkspaceResolverFactory` (and, for the top-level
    /// facade's default behavior, in `PKRuntime.Configuration`). Hosts that want the
    /// bundled local-filesystem default can build one via `WorkspaceResolverFactory.makeDefault`
    /// or use the `workspaceCreator:`-based convenience initializer below.
    ///
    /// Not `public`: `promptHistoryRegistry`'s type (`TimelinePromptJournals`) is
    /// package-internal, so this initializer can't be exposed with that parameter present.
    /// Same-module callers (the facade) use it directly; public callers use the overload below.
    init(
        stores: Stores,
        workspaceProfile: WorkspaceProfile,
        resolver: any WorkspaceResolver,
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        promptHistoryRegistry: TimelinePromptJournals? = nil,
        finalizer: TurnFinalizer? = nil,
        taskRegistry: TimelineTaskRegistry? = nil,
        workspaceExecutionCoordinator: WorkspaceExecutionCoordinator? = nil,
        timelineAuthorityCoordinator: TimelineAuthorityCoordinator? = nil
    ) {
        timelineStore = stores.timelineStore
        messageStore = stores.messageStore
        workspaceStore = stores.workspaceStore
        workspaceBindingRepository = stores.workspaceBindingRepository
        runtimeRepository = stores.runtimeRepository
        toolPersistence = stores.toolPersistence
        self.workspaceProfile = workspaceProfile
        self.runtimeToolPolicy = runtimeToolPolicy
        self.promptHistoryRegistry = promptHistoryRegistry
        self.finalizer = finalizer
        self.taskRegistry = taskRegistry ?? TimelineTaskRegistry()
        self.workspaceExecutionCoordinator = workspaceExecutionCoordinator ?? WorkspaceExecutionCoordinator()
        self.timelineAuthorityCoordinator = timelineAuthorityCoordinator ?? TimelineAuthorityCoordinator()
        workspaceResolver = resolver
    }

    // MARK: - Task Management

    /// Registers a generation task for a timeline, cancelling any previous active task.
    /// The `turnID` scopes the registration so a stale turn's terminal cleanup cannot evict a
    /// newer turn's entry.
    @discardableResult
    func registerTask(_ task: Task<Void, Never>, turnID: UUID, for timelineID: UUID) async -> Bool {
        await taskRegistry.register(task, turnID: turnID, for: timelineID)
    }

    /// Explicitly cancels an ongoing generation task for a timeline. The entry is removed by
    /// the task's own terminal path.
    func cancelGeneration(for timelineID: UUID) async {
        await taskRegistry.cancelActive(for: timelineID)
    }

    /// Removes the task entry on a terminal path, but only if `turnID` is still the active turn.
    /// A stale turn (superseded by a newer one) is a no-op.
    func removeTask(turnID: UUID, for timelineID: UUID) async {
        await taskRegistry.removeIfActive(turnID: turnID, for: timelineID)
    }

    /// Turn-scoped cancellation: only cancels if `turnID` is still the active turn. Returns
    /// `false` for a stale turn that has been superseded.
    @discardableResult
    func cancelGeneration(turnID: UUID, for timelineID: UUID) async -> Bool {
        await taskRegistry.cancel(turnID: turnID, for: timelineID)
    }

    /// Cancels any active task for the timeline and awaits its termination (bounded cleanup
    /// for eviction/deletion).
    func cancelActiveTaskAndAwait(for timelineID: UUID) async {
        await taskRegistry.cancelAndAwait(for: timelineID)
    }

    /// Snapshots the currently registered task without cancelling or removing it.
    /// Awaiting the returned task joins its complete terminal path, including registry cleanup.
    func activeTaskCompletion(for timelineID: UUID) async -> Task<Void, Never>? {
        await taskRegistry.activeTaskCompletion(for: timelineID)
    }

    /// Whether a generation task is currently registered for the timeline.
    func hasActiveTask(for timelineID: UUID) async -> Bool {
        await taskRegistry.hasActiveTurn(for: timelineID)
    }

    /// The Turn this process is currently driving or preparing for the timeline, or `nil` when it
    /// owns none. Liveness classification uses this to tell an in-process Turn from an orphan.
    func activeTurnID(for timelineID: UUID) async -> UUID? {
        await taskRegistry.activeTurnID(for: timelineID)
    }

    /// Records that this process admitted a Turn whose stream-driving task has not been registered
    /// yet, closing the admission-to-registration ownership window (ADR 0010).
    func markAdmitted(turnID: UUID, for timelineID: UUID) async {
        await taskRegistry.markAdmitted(turnID: turnID, for: timelineID)
    }

    /// Drops the admission marker when preparation fails before a task could register.
    func removeAdmitted(turnID: UUID, for timelineID: UUID) async {
        await taskRegistry.removeAdmitted(turnID: turnID, for: timelineID)
    }

    /// Rejects authority-changing operations while a Turn still owns this Timeline's execution
    /// context. Reads remain available. The durable repository is authoritative.
    func requireExecutionContextMutable(for timelineID: UUID) async throws {
        if let active = try await runtimeRepository.fetchActiveTurn(for: timelineID) {
            throw TimelineRuntimeRepositoryError.timelineBusy(
                timelineID: timelineID,
                activeTurnID: active.identity.turnID
            )
        }
    }

    /// Revalidates the durable Workspace binding immediately before tool execution.
    func requireWorkspaceBinding(_ workspaceID: UUID, for timelineID: UUID) async throws {
        if let owner = try await workspaceBindingRepository.timelineID(for: workspaceID) {
            guard owner == timelineID else {
                throw WorkspaceBindingRepositoryError.workspaceAlreadyBound(
                    workspaceID: workspaceID,
                    timelineID: owner
                )
            }
            return
        }
        // A missing repository row is a hard denial.
        throw WorkspaceBindingRepositoryError.bindingNotFound(
            workspaceID: workspaceID,
            timelineID: timelineID
        )
    }

    /// Executes work under the process-local FIFO lane for an ordinary Workspace.
    func withWorkspaceExecution<T: Sendable>(
        _ workspaceID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await workspaceExecutionCoordinator.withWorkspaceExecution(workspaceID: workspaceID, operation: operation)
    }

    /// Serializes Turn admission and Timeline authority mutations under one per-Timeline lane.
    func withTimelineAuthority<T: Sendable>(
        _ timelineID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await timelineAuthorityCoordinator.withTimeline(timelineID, operation: operation)
    }
}

// MARK: - Queries & Agent Support

extension TimelineManager {
    /// Pure lookup: retrieves a timeline by its ID without mutating `updatedAt`.
    /// Callers that want to record activity should call ``touchTimeline(id:)`` explicitly.
    func timeline(id: UUID) -> TimelineRecord? {
        timelines[id]
    }

    /// Explicitly marks a timeline as recently active by bumping its `updatedAt` timestamp.
    /// No-op if the timeline isn't cached in memory.
    func touchTimeline(id: UUID) {
        guard var timeline = timelines[id] else { return }
        timeline.updatedAt = Date()
        timelines[id] = timeline
    }

    /// Keeps the coordinator's compatibility cache aligned after Agent attachment mutations
    /// commit through the shared Timeline store.
    func replaceCachedTimelineIfPresent(_ timeline: TimelineRecord) {
        guard timelines[timeline.id] != nil else { return }
        timelines[timeline.id] = timeline
    }

    /// Fetches the message history for a specific timeline from persistence.
    func getHistory(for timelineID: UUID) async throws -> [Message] {
        let timelineMessages = try await messageStore.fetchMessages(for: timelineID)
        return timelineMessages.map { $0.toMessage() }
    }

    /// Lists all active (non-archived) timelines from persistence.
    func listTimelines() async throws -> [TimelineRecord] {
        return try await timelineStore.fetchAllTimelines(includeArchived: false)
    }
}

// MARK: - PKTool Management

extension TimelineManager {
    /// Enabled tools for an active timeline (empty if the timeline has no active tool manager).
    /// A pure query, not subordinate-manager access: it does not expose `TimelineToolRegistry`
    /// itself (PKV3-010), only the read a host needs to merge system tools with request-scoped
    /// ones before sending a turn.
    func enabledTools(for timelineID: UUID) async -> [AnyTool] {
        guard let toolManager = toolManagers[timelineID] else { return [] }
        return await toolManager.getEnabledTools()
    }

    /// Enables a tool by id on an active timeline. No-op (does not throw) if the timeline has
    /// no active tool manager; returns whether a tool manager was found to act on.
    @discardableResult
    func enableTool(id: String, for timelineID: UUID) async -> Bool {
        guard let toolManager = toolManagers[timelineID] else { return false }
        await toolManager.enableTool(id: id)
        return true
    }

    /// Disables a tool by id on an active timeline. No-op (does not throw) if the timeline has
    /// no active tool manager; returns whether a tool manager was found to act on.
    @discardableResult
    func disableTool(id: String, for timelineID: UUID) async -> Bool {
        guard let toolManager = toolManagers[timelineID] else { return false }
        await toolManager.disableTool(id: id)
        return true
    }

    func getToolSource(toolName: String, for timelineID: UUID) async throws -> String? {
        guard timelines[timelineID] != nil else { return nil }

        if let toolManager = toolManagers[timelineID] {
            let systemTools = await toolManager.getAvailableTools()
            if systemTools.contains(where: { $0.callName == toolName }) {
                return "System"
            }
        }

        do {
            let workspaceIDs = try await workspaceBindingRepository
                .bindings(for: timelineID)
                .map(\.workspaceID)
            return try await toolPersistence.fetchToolSource(
                named: toolName,
                in: workspaceIDs,
                preferring: nil
            )
        } catch {
            logger.error("""
            getToolSource failed — toolName: \(toolName), timeline: \(timelineID.uuidString.prefix(8)), \
            operation: fetchToolSource, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            throw TimelineError.unavailable
        }
    }
}

// MARK: - Internal Subordinate-Manager Access (PKV3-010: not part of the public surface)

extension TimelineManager {
    /// Returns the current liveness version for a timeline. A missing entry is the initial version.
    func timelineLivenessVersion(for timelineID: UUID) -> UInt64 {
        timelineLivenessVersions[timelineID] ?? 0
    }

    /// Invalidates operations that captured an earlier liveness version for the timeline and marks
    /// the deletion active before its first suspension.
    func invalidateTimelineLiveness(for timelineID: UUID) {
        timelineLivenessVersions[timelineID] = (timelineLivenessVersions[timelineID] ?? 0) &+ 1
        timelinesBeingPermanentlyDeleted.insert(timelineID)
    }

    /// Advances the timeline's liveness version without marking it permanently deleted. Eviction
    /// uses this to reject in-flight mutations against a Timeline whose cache is being torn down
    /// while still allowing the Timeline to be hydrated again later.
    func bumpTimelineLiveness(for timelineID: UUID) {
        timelineLivenessVersions[timelineID] = (timelineLivenessVersions[timelineID] ?? 0) &+ 1
    }

    /// Closes a deletion epoch. Advancing again prevents operations that captured the in-progress
    /// version from saving after cleanup completes, while allowing a fresh retry if cleanup was
    /// partial and the persisted row remains.
    func completeTimelineDeletionLiveness(for timelineID: UUID) {
        timelineLivenessVersions[timelineID] = (timelineLivenessVersions[timelineID] ?? 0) &+ 1
        timelinesBeingPermanentlyDeleted.remove(timelineID)
    }

    /// Throws when a timeline was permanently deleted after an operation captured its version.
    func requireTimelineLiveness(for timelineID: UUID, version: UInt64) throws {
        guard !timelinesBeingPermanentlyDeleted.contains(timelineID),
              timelineLivenessVersion(for: timelineID) == version
        else {
            throw TimelineError.timelineNotFound
        }
    }

    /// Retrieves the tool manager for a timeline if it is active.
    func getToolManager(for timelineID: UUID) -> TimelineToolRegistry? {
        return toolManagers[timelineID]
    }

    func consumeDegradations(for timelineID: UUID) -> [TurnDiagnostic] {
        timelineDegradations.removeValue(forKey: timelineID) ?? []
    }
}
