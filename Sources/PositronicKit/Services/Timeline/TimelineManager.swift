import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared
import PKUtilities

/// Manages conversation timelines, their associated context, and tool execution environments.
///
/// `TimelineManager` is the public coordinator/cache owner for timelines: it holds the
/// in-memory `timelines`/`turnBriefingBuilders`/`toolManagers` caches and the
/// `taskRegistry` (send-scoped active-task tracking), and manages lifecycle,
/// workspace-attachment, and tool-policy behavior. Concrete workspace behavior
/// remains behind `WorkspaceResolver` / `WorkspaceFactory` / `Workspace` so hosts can
/// supply local or remote workspace implementations without changing core orchestration.
public actor TimelineManager {
    public struct RuntimeToolPolicy: Sendable, Equatable {
        public let installFilesystemTools: Bool
        public let installTimelineObservationTools: Bool
        public let installTimelineSendTool: Bool

        public init(
            installFilesystemTools: Bool = true,
            installTimelineObservationTools: Bool = true,
            installTimelineSendTool: Bool = true
        ) {
            self.installFilesystemTools = installFilesystemTools
            self.installTimelineObservationTools = installTimelineObservationTools
            self.installTimelineSendTool = installTimelineSendTool
        }

        public static let `default` = RuntimeToolPolicy()
        public static let denyAll = RuntimeToolPolicy(
            installFilesystemTools: false,
            installTimelineObservationTools: false,
            installTimelineSendTool: false
        )
    }

    public struct Stores: Sendable {
        public let timelineStore: any TimelinePersistenceProtocol
        public let messageStore: any MessageStoreProtocol
        public let workspaceStore: any WorkspaceStore
        public let toolPersistence: any ToolPersistenceProtocol
        public let memoryStore: any MemoryStoreProtocol

        public init(
            timelineStore: any TimelinePersistenceProtocol,
            messageStore: any MessageStoreProtocol,
            workspaceStore: any WorkspaceStore,
            toolPersistence: any ToolPersistenceProtocol,
            memoryStore: any MemoryStoreProtocol = InMemoryMemoryStore()
        ) {
            self.timelineStore = timelineStore
            self.messageStore = messageStore
            self.workspaceStore = workspaceStore
            self.toolPersistence = toolPersistence
            self.memoryStore = memoryStore
        }
    }

    // MARK: - State

    /// In-memory cache of active timelines.
    var timelines: [UUID: Timeline] = [:]

    /// Context managers responsible for RAG and context gathering for each timeline.
    var turnBriefingBuilders: [UUID: TurnBriefingBuilder] = [:]

    /// Tool managers handling tool registration and availability for each timeline.
    var toolManagers: [UUID: TimelineToolRegistry] = [:]

    /// Preparation degradations discovered while hydrating a timeline's runtime components.
    var timelineDegradations: [UUID: [TurnDiagnostic]] = [:]

    /// Send-scoped registry of the active stream-driving task for each timeline. Replaces the
    /// former `activeTasks` dict so cancellation is send-scoped (a stale send cannot evict or
    /// cancel a newer one) and eviction/deletion can await bounded cleanup.
    let taskRegistry: TimelineTaskRegistry

    // MARK: - Dependencies

    let timelineStore: any TimelinePersistenceProtocol
    let messageStore: any MessageStoreProtocol
    let workspaceStore: any WorkspaceStore
    let toolPersistence: any ToolPersistenceProtocol
    let memoryStore: any MemoryStoreProtocol
    let embeddingService: any EmbeddingServiceProtocol

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
    /// construction; they don't reach back through `TimelineManager` to get one.
    let workspaceResolver: any WorkspaceResolver
    let sectionProviders: [any PromptSectionProviding]
    let runtimeToolPolicy: RuntimeToolPolicy
    /// Per-timeline prompt-history/journal-diff registry. When non-nil, `evictTimelineFromMemory(id:)`
    /// and `cleanupStaleTimelines(maxAge:)` evict the corresponding history entry alongside the
    /// in-memory caches, so deleted/stale timelines don't leak journal-diff state.
    let promptHistoryRegistry: TimelinePromptJournals?

    let logger = Logger.module(named: "timeline-manager")

    // MARK: - Initialization

    /// Designated initializer: accepts a fully-formed `any WorkspaceResolver` directly.
    ///
    /// `TimelineManager` does not know how to assemble the default catalog/factory/resolver
    /// stack; that composition lives in `WorkspaceResolverFactory` (and, for the top-level
    /// facade's default behavior, in `PositronicKit.Configuration`). Hosts that want the
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
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        promptHistoryRegistry: TimelinePromptJournals? = nil,
        taskRegistry: TimelineTaskRegistry? = nil
    ) {
        timelineStore = stores.timelineStore
        messageStore = stores.messageStore
        workspaceStore = stores.workspaceStore
        toolPersistence = stores.toolPersistence
        memoryStore = stores.memoryStore
        self.embeddingService = embeddingService
        self.workspaceProfile = workspaceProfile
        self.sectionProviders = sectionProviders
        self.runtimeToolPolicy = runtimeToolPolicy
        self.promptHistoryRegistry = promptHistoryRegistry
        self.taskRegistry = taskRegistry ?? TimelineTaskRegistry()
        workspaceResolver = resolver
    }

    /// Designated initializer taking a `workspaceRoot` (legacy / backward-compatible).
    ///
    /// Maps to `.hostManaged(root: seedNotes: .default)`, preserving the pre-PKRR-029 behavior
    /// of callers that pass an explicit `workspaceRoot`.
    init(
        stores: Stores,
        workspaceRoot: URL,
        resolver: any WorkspaceResolver,
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        promptHistoryRegistry: TimelinePromptJournals? = nil,
        taskRegistry: TimelineTaskRegistry? = nil
    ) {
        self.init(
            stores: stores,
            workspaceProfile: .hostManaged(root: workspaceRoot, seedNotes: .default),
            resolver: resolver,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: promptHistoryRegistry,
            taskRegistry: taskRegistry
        )
    }

    /// Public designated initializer: accepts a fully-formed `any WorkspaceResolver` directly.
    public init(
        stores: Stores,
        workspaceRoot: URL,
        resolver: any WorkspaceResolver,
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService()
    ) {
        self.init(
            stores: stores,
            workspaceProfile: .hostManaged(root: workspaceRoot, seedNotes: .default),
            resolver: resolver,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService
        )
    }

    /// Public designated initializer with an explicit workspace profile (PKRR-029).
    ///
    /// Use `.noWorkspace` for a side-effect-free default, `.ephemeralWorkspace` for a
    /// self-cleaning scratch directory, or `.hostManaged` to preserve the pre-PKRR-029
    /// explicit-`workspaceRoot` behavior.
    public init(
        stores: Stores,
        workspaceProfile: WorkspaceProfile,
        resolver: any WorkspaceResolver,
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService()
    ) {
        self.init(
            stores: stores,
            workspaceProfile: workspaceProfile,
            resolver: resolver,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: nil
        )
    }

    /// Convenience initializer that builds the bundled default `WorkspaceResolver` (local
    /// filesystem catalog + injected factory) via `WorkspaceResolverFactory`, preserving the
    /// prior `workspaceCreator:`-based construction ergonomics without TimelineManager itself
    /// composing `DefaultWorkspaceCatalog`/`DefaultWorkspaceResolver`.
    init(
        stores: Stores,
        workspaceProfile: WorkspaceProfile,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        promptHistoryRegistry: TimelinePromptJournals? = nil,
        taskRegistry: TimelineTaskRegistry? = nil
    ) {
        let catalogRoot = workspaceProfile.catalogRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("positronickit-workspaces", isDirectory: true)
        self.init(
            stores: stores,
            workspaceProfile: workspaceProfile,
            resolver: WorkspaceResolverFactory.makeDefault(
                workspaceRoot: catalogRoot,
                workspaceStore: stores.workspaceStore,
                workspaceCreator: workspaceCreator
            ),
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: promptHistoryRegistry,
            taskRegistry: taskRegistry
        )
    }

    /// Convenience initializer (legacy `workspaceRoot` form). Maps to `.hostManaged`.
    init(
        stores: Stores,
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        promptHistoryRegistry: TimelinePromptJournals? = nil,
        taskRegistry: TimelineTaskRegistry? = nil
    ) {
        self.init(
            stores: stores,
            workspaceProfile: .hostManaged(root: workspaceRoot, seedNotes: .default),
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: promptHistoryRegistry,
            taskRegistry: taskRegistry
        )
    }

    public init(
        stores: Stores,
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService()
    ) {
        self.init(
            stores: stores,
            workspaceRoot: workspaceRoot,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: nil
        )
    }

    /// Public convenience initializer with an explicit workspace profile (PKRR-029).
    public init(
        stores: Stores,
        workspaceProfile: WorkspaceProfile,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService()
    ) {
        self.init(
            stores: stores,
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: nil
        )
    }

    /// Public convenience initializer with an explicit workspace profile and in-memory stores.
    public init(
        workspaceProfile: WorkspaceProfile = .noWorkspace,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default
    ) {
        self.init(
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: nil
        )
    }

    public init(
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default
    ) {
        self.init(
            workspaceRoot: workspaceRoot,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: nil
        )
    }

    init(
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        promptHistoryRegistry: TimelinePromptJournals? = nil,
        taskRegistry: TimelineTaskRegistry? = nil
    ) {
        self.init(
            stores: .init(
                timelineStore: InMemoryTimelinePersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: InMemoryWorkspacePersistence(),
                toolPersistence: InMemoryToolPersistence()
            ),
            workspaceRoot: workspaceRoot,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: promptHistoryRegistry,
            taskRegistry: taskRegistry
        )
    }

    init(
        workspaceProfile: WorkspaceProfile,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        promptHistoryRegistry: TimelinePromptJournals? = nil,
        taskRegistry: TimelineTaskRegistry? = nil
    ) {
        self.init(
            stores: .init(
                timelineStore: InMemoryTimelinePersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: InMemoryWorkspacePersistence(),
                toolPersistence: InMemoryToolPersistence()
            ),
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: promptHistoryRegistry,
            taskRegistry: taskRegistry
        )
    }

    // MARK: - Prompt & Extension Support

    /// Gathers additional prompt sections from all registered `PromptSectionProviding` instances.
    public func gatherExtensionSections(
        timelineId: UUID,
        agentInstanceId: UUID?,
        message: String
    ) async -> [any Prompt] {
        let buildContext = PromptBuildContext(
            timelineId: timelineId,
            agentInstanceId: agentInstanceId,
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
    public func registerTask(_ task: Task<Void, Never>, sendID: UUID, for timelineId: UUID) async {
        await taskRegistry.register(task, sendID: sendID, for: timelineId)
    }

    /// Explicitly cancels an ongoing generation task for a timeline. The entry is removed by
    /// the task's own terminal path.
    public func cancelGeneration(for timelineId: UUID) async {
        await taskRegistry.cancelActive(for: timelineId)
    }

    /// Removes the task entry on a terminal path, but only if `sendID` is still the active send.
    /// A stale send (superseded by a newer one) is a no-op.
    public func removeTask(sendID: UUID, for timelineId: UUID) async {
        await taskRegistry.removeIfActive(sendID: sendID, for: timelineId)
    }

    /// Send-scoped cancellation: only cancels if `sendID` is still the active send. Returns
    /// `false` for a stale send that has been superseded.
    @discardableResult
    public func cancelGeneration(sendID: UUID, for timelineId: UUID) async -> Bool {
        await taskRegistry.cancel(sendID: sendID, for: timelineId)
    }

    /// Cancels any active task for the timeline and awaits its termination (bounded cleanup
    /// for eviction/deletion).
    public func cancelActiveTaskAndAwait(for timelineId: UUID) async {
        await taskRegistry.cancelAndAwait(for: timelineId)
    }

    /// Whether a generation task is currently registered for the timeline.
    func hasActiveTask(for timelineId: UUID) async -> Bool {
        await taskRegistry.hasActiveSend(for: timelineId)
    }
}

// MARK: - Queries & Agent Support

public extension TimelineManager {
    /// Pure lookup: retrieves a timeline by its ID without mutating `updatedAt`.
    /// Callers that want to record activity should call ``touchTimeline(id:)`` explicitly.
    func timeline(id: UUID) -> Timeline? {
        timelines[id]
    }

    /// Explicitly marks a timeline as recently active by bumping its `updatedAt` timestamp.
    /// No-op if the timeline isn't cached in memory.
    func touchTimeline(id: UUID) {
        guard var timeline = timelines[id] else { return }
        timeline.updatedAt = Date()
        timelines[id] = timeline
    }

    /// Fetches the message history for a specific timeline from persistence.
    func getHistory(for timelineId: UUID) async throws -> [Message] {
        let conversationMessages = try await messageStore.fetchMessages(for: timelineId)
        return conversationMessages.map { $0.toMessage() }
    }

    /// Lists all active (non-archived) timelines from persistence.
    func listTimelines() async throws -> [Timeline] {
        return try await timelineStore.fetchAllTimelines(includeArchived: false)
    }
}

// MARK: - Tool Management

public extension TimelineManager {
    func findWorkspaceForTool(_ tool: ToolReference, in workspaceIds: [UUID]) async throws
        -> UUID?
    {
        return try await toolPersistence.findWorkspaceId(forToolId: tool.toolId, in: workspaceIds)
    }

    /// Enabled tools for an active timeline (empty if the timeline has no active tool manager).
    /// A pure query, not subordinate-manager access: it does not expose `TimelineToolRegistry`
    /// itself (PKV3-010), only the read a host needs to merge system tools with request-scoped
    /// ones before sending a turn.
    func enabledTools(for timelineId: UUID) async -> [AnyTool] {
        guard let toolManager = toolManagers[timelineId] else { return [] }
        return await toolManager.getEnabledTools()
    }

    /// Enables a tool by id on an active timeline. No-op (does not throw) if the timeline has
    /// no active tool manager; returns whether a tool manager was found to act on.
    @discardableResult
    func enableTool(id: String, for timelineId: UUID) async -> Bool {
        guard let toolManager = toolManagers[timelineId] else { return false }
        await toolManager.enableTool(id: id)
        return true
    }

    /// Disables a tool by id on an active timeline. No-op (does not throw) if the timeline has
    /// no active tool manager; returns whether a tool manager was found to act on.
    @discardableResult
    func disableTool(id: String, for timelineId: UUID) async -> Bool {
        guard let toolManager = toolManagers[timelineId] else { return false }
        await toolManager.disableTool(id: id)
        return true
    }

    func getToolSource(toolId: String, for timelineId: UUID) async throws -> String? {
        guard let timeline = timelines[timelineId] else { return nil }

        if let toolManager = toolManagers[timelineId] {
            let systemTools = await toolManager.getAvailableTools()
            if systemTools.contains(where: { $0.callName == toolId }) {
                return "System"
            }
        }

        do {
            return try await toolPersistence.fetchToolSource(
                toolId: toolId,
                workspaceIds: timeline.attachedWorkspaceIds,
                primaryWorkspaceId: nil
            )
        } catch {
            logger.error("""
            getToolSource failed — toolId: \(toolId), timeline: \(timelineId.uuidString.prefix(8)), \
            operation: fetchToolSource, error: \(ErrorKit.userFriendlyMessage(for: error))
            """)
            throw TimelineError.unavailable
        }
    }
}

// MARK: - Errors

public enum TimelineError: PKError, Equatable {
    case timelineNotFound
    case unavailable
    case corrupt(String)
    case permissionDenied
    case invalidState(String)

    public var errorDomain: String {
        PKErrorDomain.timeline
    }

    public var errorCode: Int {
        switch self {
        case .timelineNotFound: return 6001
        case .unavailable: return 6002
        case .corrupt: return 6003
        case .permissionDenied: return 6004
        case .invalidState: return 6005
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .timelineNotFound:
            return "The requested chat timeline could not be found."
        case .unavailable:
            return "The timeline store is currently unavailable. Please try again."
        case .corrupt:
            return "The timeline data appears to be corrupted. Please contact support."
        case .permissionDenied:
            return "Permission denied when accessing the timeline store."
        case .invalidState:
            return "The timeline is in an invalid state for this operation."
        }
    }

    public var remediation: String? {
        switch self {
        case .unavailable:
            return "Wait a moment and retry the operation."
        case .corrupt:
            return "Contact your administrator to inspect the persistence backend."
        case .permissionDenied:
            return "Verify that the runtime has the required access permissions."
        case .invalidState:
            return nil
        case .timelineNotFound:
            return nil
        }
    }
}

/// A typed record of a best-effort failure that was downgraded rather than thrown.
/// Carries stable error identity and operation metadata so callers and operators can
/// see *what* failed and *why*, rather than observing a silent empty/nil result.
public struct StoreDegradation: Sendable {
    public let operation: String
    public let entityId: String
    public let errorIdentity: ChatEvent.ErrorIdentity?
    public let message: String

    public init(operation: String, entityId: String, error: Error) {
        self.operation = operation
        self.entityId = entityId
        self.errorIdentity = .extracting(from: error)
        self.message = ErrorKit.userFriendlyMessage(for: error)
    }

    public init(operation: String, entityId: String, errorIdentity: ChatEvent.ErrorIdentity?, message: String) {
        self.operation = operation
        self.entityId = entityId
        self.errorIdentity = errorIdentity
        self.message = message
    }
}

/// The result of a workspace query, including any best-effort degradations encountered
/// while resolving individual workspaces. The timeline-level store failure is thrown as
/// a `TimelineError` (not collapsed into an empty result); individual workspace fetch
/// failures are collected as `degradations` so the caller can log or surface them.
public struct WorkspaceQueryResult: Sendable {
    public let primary: WorkspaceReference?
    public let attached: [WorkspaceReference]
    public let degradations: [StoreDegradation]

    public init(primary: WorkspaceReference?, attached: [WorkspaceReference], degradations: [StoreDegradation] = []) {
        self.primary = primary
        self.attached = attached
        self.degradations = degradations
    }
}

/// The result of ``TimelineManager/deleteTimelinePermanently(id:)``.
///
/// Permanent deletion is best-effort across multiple stores (timeline row, messages,
/// workspace attachments). When every store succeeds, `isComplete` is `true` and
/// `degradations` is empty. When one or more stores fail, the remaining stores are still
/// attempted and each failure is recorded as a ``StoreDegradation`` so the caller can log,
/// retry, or surface the partial cleanup.
public struct TimelineDeletionResult: Sendable {
    public let timelineId: UUID
    public let degradations: [StoreDegradation]

    /// `true` when every persisted record was removed; `false` when one or more stores failed.
    public var isComplete: Bool { degradations.isEmpty }

    public init(timelineId: UUID, degradations: [StoreDegradation] = []) {
        self.timelineId = timelineId
        self.degradations = degradations
    }
}

// MARK: - Internal Subordinate-Manager Access (PKV3-010: not part of the public surface)

extension TimelineManager {
    /// Retrieves the turn briefing builder for a timeline if it is active.
    func getTurnBriefingBuilder(for timelineId: UUID) -> TurnBriefingBuilder? {
        return turnBriefingBuilders[timelineId]
    }

    /// Retrieves the tool manager for a timeline if it is active.
    func getToolManager(for timelineId: UUID) -> TimelineToolRegistry? {
        return toolManagers[timelineId]
    }

    func consumeDegradations(for timelineId: UUID) -> [TurnDiagnostic] {
        timelineDegradations.removeValue(forKey: timelineId) ?? []
    }
}
