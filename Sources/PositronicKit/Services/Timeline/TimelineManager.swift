import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared

/// Manages conversation timelines, their associated context, and tool execution environments.
///
/// The `TimelineManager` is the public coordinator/cache owner for timelines: it holds the
/// in-memory `timelines`/`contextManagers`/`toolManagers`/`activeTasks` caches and forwards
/// lifecycle, workspace-attachment, and tool-policy behavior to three package-internal services:
///
/// - `TimelineLifecycleService` — create / hydrate / update-title / delete / cleanup.
/// - `WorkspaceAttachmentService` — attach / detach / getWorkspaces / getWorkspace.
/// - `RuntimeToolPolicyFactory` — build a `TimelineToolManager` from a `RuntimeToolPolicy`.
///
/// Each service operates on the caches through the narrow `TimelineCache` seam (which
/// `TimelineManager` conforms to), keeping the public surface stable while giving each concern
/// its own module and test surface. Concrete workspace behavior remains behind `WorkspaceManager`
/// / `WorkspaceCreating` / `WorkspaceProtocol` so hosts can supply local or remote workspace
/// implementations without changing core orchestration.
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
        public let workspaceStore: any WorkspacePersistenceProtocol
        public let toolPersistence: any ToolPersistenceProtocol
        public let memoryStore: any MemoryStoreProtocol

        public init(
            timelineStore: any TimelinePersistenceProtocol,
            messageStore: any MessageStoreProtocol,
            workspaceStore: any WorkspacePersistenceProtocol,
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
    var contextManagers: [UUID: ContextManager] = [:]

    /// Tool managers handling tool registration and availability for each timeline.
    var toolManagers: [UUID: TimelineToolManager] = [:]

    /// Ongoing generation tasks for each timeline.
    var activeTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Dependencies

    let timelineStore: any TimelinePersistenceProtocol
    let messageStore: any MessageStoreProtocol
    let workspaceStore: any WorkspacePersistenceProtocol
    let toolPersistence: any ToolPersistenceProtocol
    let memoryStore: any MemoryStoreProtocol
    let embeddingService: any EmbeddingServiceProtocol

    let workspaceRoot: URL
    public let workspaceManager: any WorkspaceManagerProtocol
    let sectionProviders: [any PromptSectionProviding]
    let runtimeToolPolicy: RuntimeToolPolicy
    /// Per-timeline prompt-history/journal-diff registry. When non-nil, `deleteTimeline(id:)`
    /// and `cleanupStaleTimelines(maxAge:)` evict the corresponding history entry alongside the
    /// in-memory caches, so deleted/stale timelines don't leak journal-diff state.
    let promptHistoryRegistry: TimelinePromptHistoryRegistry?

    // MARK: - Initialization

    public init(
        stores: Stores,
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceCreating = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        promptHistoryRegistry: TimelinePromptHistoryRegistry? = nil
    ) {
        timelineStore = stores.timelineStore
        messageStore = stores.messageStore
        workspaceStore = stores.workspaceStore
        toolPersistence = stores.toolPersistence
        memoryStore = stores.memoryStore
        self.embeddingService = embeddingService
        self.workspaceRoot = workspaceRoot
        self.sectionProviders = sectionProviders
        self.runtimeToolPolicy = runtimeToolPolicy
        self.promptHistoryRegistry = promptHistoryRegistry

        workspaceManager = WorkspaceManager(
            repository: AgentWorkspaceService(
                workspaceRoot: workspaceRoot,
                workspacePersistence: stores.workspaceStore
            ),
            workspaceCreator: workspaceCreator
        )
    }

    public init(
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceCreating = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        promptHistoryRegistry: TimelinePromptHistoryRegistry? = nil
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
            promptHistoryRegistry: promptHistoryRegistry
        )
    }

    // MARK: - Service Accessors

    /// Constructs the lifecycle service with the coordinator's caches and dependencies. Computed
    /// (rather than stored) so the service can capture `self` as its ``TimelineCache`` without
    /// ordering constraints in the actor's initializer.
    private var lifecycleService: TimelineLifecycleService {
        TimelineLifecycleService(
            cache: self,
            timelineStore: timelineStore,
            messageStore: messageStore,
            workspaceStore: workspaceStore,
            workspaceManager: workspaceManager,
            memoryStore: memoryStore,
            embeddingService: embeddingService,
            workspaceRoot: workspaceRoot,
            promptHistoryRegistry: promptHistoryRegistry,
            runtimeToolPolicy: runtimeToolPolicy
        )
    }

    private var attachmentService: WorkspaceAttachmentService {
        WorkspaceAttachmentService(
            cache: self,
            timelineStore: timelineStore,
            workspaceStore: workspaceStore,
            workspaceManager: workspaceManager
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
    public func registerTask(_ task: Task<Void, Never>, for timelineId: UUID) {
        activeTasks[timelineId]?.cancel()
        activeTasks[timelineId] = task
    }

    /// Explicitly cancels an ongoing generation task for a timeline.
    public func cancelGeneration(for timelineId: UUID) {
        activeTasks[timelineId]?.cancel()
        activeTasks.removeValue(forKey: timelineId)
    }
}

// MARK: - Lifecycle (delegates to TimelineLifecycleService)

public extension TimelineManager {
    /// Creates a new conversation timeline, initializes its workspace, and saves it to persistence.
    func createTimeline(title: String = "New Conversation") async throws -> Timeline {
        try await lifecycleService.createTimeline(title: title)
    }

    /// Reconstructs a timeline and its components from persistence.
    func hydrateTimeline(id: UUID) async throws {
        try await lifecycleService.hydrateTimeline(id: id)
    }

    /// Updates the title of a specific timeline.
    func updateTimelineTitle(id: UUID, title: String) async throws {
        try await lifecycleService.updateTimelineTitle(id: id, title: title)
    }

    /// Evicts all in-memory runtime state for a timeline. Does not touch persistence. See
    /// `TimelineLifecycleService.deleteTimeline(id:)` for the runtime-eviction seam; callers
    /// that also want to delete the persisted timeline must call
    /// `timelineStore.deleteTimeline(id:)` alongside this (see `TimelineAPIController.delete`
    /// in Monad and `AgentInstanceManager.deleteInstance`).
    func deleteTimeline(id: UUID) async {
        await lifecycleService.deleteTimeline(id: id)
    }

    /// Removes active timelines from memory that have not been updated within the
    /// specified interval. Only evicts in-memory state; persisted timelines are
    /// unaffected. Also drops the corresponding prompt-history entries when a
    /// registry was injected.
    func cleanupStaleTimelines(maxAge: TimeInterval) async {
        await lifecycleService.cleanupStaleTimelines(maxAge: maxAge)
    }
}

// MARK: - Queries & Agent Support

public extension TimelineManager {
    /// Retrieves a timeline by its ID and updates its `updatedAt` timestamp.
    func getTimeline(id: UUID) -> Timeline? {
        guard var timeline = timelines[id] else { return nil }
        timeline.updatedAt = Date()
        timelines[id] = timeline
        return timeline
    }

    /// Retrieves the tool manager for a timeline if it is active.
    func getToolManager(for timelineId: UUID) -> TimelineToolManager? {
        return toolManagers[timelineId]
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

    func getToolSource(toolId: String, for timelineId: UUID) async -> String? {
        guard let timeline = timelines[timelineId] else { return nil }

        if let toolManager = toolManagers[timelineId] {
            let systemTools = await toolManager.getAvailableTools()
            if systemTools.contains(where: { $0.id == toolId }) {
                return "System"
            }
        }

        return try? await toolPersistence.fetchToolSource(
            toolId: toolId,
            workspaceIds: timeline.attachedWorkspaceIds,
            primaryWorkspaceId: nil
        )
    }
}

// MARK: - Workspace Management (delegates to WorkspaceAttachmentService)

public extension TimelineManager {
    func attachWorkspace(_ workspaceId: UUID, to timelineId: UUID) async throws {
        try await attachmentService.attachWorkspace(workspaceId, to: timelineId)
    }

    func detachWorkspace(_ workspaceId: UUID, from timelineId: UUID) async throws {
        try await attachmentService.detachWorkspace(workspaceId, from: timelineId)
    }

    func getWorkspaces(for timelineId: UUID) async -> (primary: WorkspaceReference?, attached: [WorkspaceReference])? {
        await attachmentService.getWorkspaces(for: timelineId)
    }

    func getWorkspace(_ id: UUID) async throws -> WorkspaceReference? {
        try await attachmentService.getWorkspace(id)
    }
}

// MARK: - Errors

public enum TimelineError: PKError {
    case timelineNotFound

    public var errorDomain: String {
        PKErrorDomain.timeline
    }

    public var errorCode: Int {
        switch self {
        case .timelineNotFound: return 6001
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .timelineNotFound:
            return "The requested chat timeline could not be found."
        }
    }
}

// MARK: - Internal ContextManager Access

extension TimelineManager {
    /// Retrieves the context manager for a timeline if it is active.
    func getContextManager(for timelineId: UUID) -> ContextManager? {
        return contextManagers[timelineId]
    }
}