import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared

/// Manages conversation timelines, their associated context, and tool execution environments.
///
/// `TimelineManager` is the public coordinator/cache owner for timelines: it holds the
/// in-memory `timelines`/`turnBriefingBuilders`/`toolManagers`/`activeTasks` caches and manages
/// lifecycle, workspace-attachment, and tool-policy behavior. Concrete workspace behavior
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

    /// Ongoing generation tasks for each timeline.
    var activeTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Dependencies

    let timelineStore: any TimelinePersistenceProtocol
    let messageStore: any MessageStoreProtocol
    let workspaceStore: any WorkspaceStore
    let toolPersistence: any ToolPersistenceProtocol
    let memoryStore: any MemoryStoreProtocol
    let embeddingService: any EmbeddingServiceProtocol

    let workspaceRoot: URL
    public let workspaceResolver: any WorkspaceResolver
    let sectionProviders: [any PromptSectionProviding]
    let runtimeToolPolicy: RuntimeToolPolicy
    /// Per-timeline prompt-history/journal-diff registry. When non-nil, `deleteTimeline(id:)`
    /// and `cleanupStaleTimelines(maxAge:)` evict the corresponding history entry alongside the
    /// in-memory caches, so deleted/stale timelines don't leak journal-diff state.
    let promptHistoryRegistry: TimelinePromptJournals?

    // MARK: - Initialization

    /// Designated initializer: accepts a fully-formed `any WorkspaceResolver` directly.
    ///
    /// `TimelineManager` does not know how to assemble the default catalog/factory/resolver
    /// stack; that composition lives in `WorkspaceResolverFactory` (and, for the top-level
    /// facade's default behavior, in `PositronicKit.Configuration`). Hosts that want the
    /// bundled local-filesystem default can build one via `WorkspaceResolverFactory.makeDefault`
    /// or use the `workspaceCreator:`-based convenience initializer below.
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
            workspaceRoot: workspaceRoot,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: nil
        )
    }

    init(
        stores: Stores,
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceCreating = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        promptHistoryRegistry: TimelinePromptJournals? = nil
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
        workspaceResolver = resolver
    }

    /// Convenience initializer that builds the bundled default `WorkspaceResolver` (local
    /// filesystem catalog + injected factory) via `WorkspaceResolverFactory`, preserving the
    /// prior `workspaceCreator:`-based construction ergonomics without TimelineManager itself
    /// composing `DefaultWorkspaceCatalog`/`DefaultWorkspaceResolver`.
    public init(
        stores: Stores,
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        promptHistoryRegistry: TimelinePromptHistoryRegistry? = nil
    ) {
        self.init(
            stores: stores,
            workspaceRoot: workspaceRoot,
            resolver: WorkspaceResolverFactory.makeDefault(
                workspaceRoot: workspaceRoot,
                workspaceStore: stores.workspaceStore,
                workspaceCreator: workspaceCreator
            ),
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: promptHistoryRegistry
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
        workspaceCreator: any WorkspaceCreating = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        promptHistoryRegistry: TimelinePromptJournals? = nil
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

// MARK: - Queries & Agent Support

public extension TimelineManager {
    /// Retrieves a timeline by its ID and updates its `updatedAt` timestamp.
    ///
    /// This method is public and consumed directly by downstream hosts (e.g. Monad's
    /// `ChatAPIController`/`TimelineAPIController`), so its touch-on-read behavior cannot be
    /// removed here without a coordinated downstream change. New internal call sites that don't
    /// need the touch side effect should prefer the pure ``timeline(id:)`` query below; callers
    /// that do want to record activity should call ``touchTimeline(id:)`` explicitly.
    func getTimeline(id: UUID) -> Timeline? {
        touchTimeline(id: id)
        return timelines[id]
    }

    /// Pure lookup: retrieves a timeline by its ID without mutating `updatedAt`.
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

    /// Retrieves the tool manager for a timeline if it is active.
    func getToolManager(for timelineId: UUID) -> TimelineToolRegistry? {
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
            if systemTools.contains(where: { $0.callName == toolId }) {
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

// MARK: - Internal TurnBriefingBuilder Access

extension TimelineManager {
    /// Retrieves the turn briefing builder for a timeline if it is active.
    func getTurnBriefingBuilder(for timelineId: UUID) -> TurnBriefingBuilder? {
        return turnBriefingBuilders[timelineId]
    }
}
