import Foundation
import PKPrompt
import PKShared
import PKUtilities

/// Deprecated v3 spelling for ``Thread``.
@available(*, deprecated, renamed: "Thread", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias Timeline = Thread

/// Deprecated v3 persistence requirements.
@available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public protocol TimelinePersistenceProtocol: DurabilityAware {
    func saveTimeline(_ timeline: Thread) async throws
    func fetchTimeline(id: UUID) async throws -> Thread?
    func fetchAllTimelines(includeArchived: Bool) async throws -> [Thread]
    func deleteTimeline(id: UUID) async throws
    func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIds: [UUID],
        dryRun: Bool
    ) async throws -> Int
}

/// Adapts an existing v3 timeline persistence conformer to the canonical thread protocol.
public actor LegacyTimelinePersistenceAdapter: ThreadPersistenceProtocol {
    private let legacy: any TimelinePersistenceProtocol

    public init(_ legacy: any TimelinePersistenceProtocol) {
        self.legacy = legacy
    }

    public nonisolated var isDurable: Bool { legacy.isDurable }

    public func saveThread(_ thread: Thread) async throws {
        try await legacy.saveTimeline(thread)
    }

    public func fetchThread(id: UUID) async throws -> Thread? {
        try await legacy.fetchTimeline(id: id)
    }

    public func fetchAllThreads(includeArchived: Bool) async throws -> [Thread] {
        try await legacy.fetchAllTimelines(includeArchived: includeArchived)
    }

    public func deleteThread(id: UUID) async throws {
        try await legacy.deleteTimeline(id: id)
    }

    public func pruneThreads(
        olderThan timeInterval: TimeInterval,
        excluding excludedThreadIDs: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        try await legacy.pruneTimelines(
            olderThan: timeInterval,
            excluding: excludedThreadIDs,
            dryRun: dryRun
        )
    }
}

/// Internal reverse adapter used while the timeline-named runtime seams are migrated.
actor ThreadPersistenceCompatibilityAdapter: TimelinePersistenceProtocol {
    private let canonical: any ThreadPersistenceProtocol

    init(_ canonical: any ThreadPersistenceProtocol) {
        self.canonical = canonical
    }

    nonisolated var isDurable: Bool { canonical.isDurable }

    func saveTimeline(_ timeline: Thread) async throws {
        try await canonical.saveThread(timeline)
    }

    func fetchTimeline(id: UUID) async throws -> Thread? {
        try await canonical.fetchThread(id: id)
    }

    func fetchAllTimelines(includeArchived: Bool) async throws -> [Thread] {
        try await canonical.fetchAllThreads(includeArchived: includeArchived)
    }

    func deleteTimeline(id: UUID) async throws {
        try await canonical.deleteThread(id: id)
    }

    func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIds: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        try await canonical.pruneThreads(
            olderThan: timeInterval,
            excluding: excludedTimelineIds,
            dryRun: dryRun
        )
    }
}

/// Bridges a legacy composite store to the canonical archiver composition without changing
/// message or memory persistence behavior.
actor LegacyThreadArchiverPersistence:
    ThreadPersistenceProtocol, MemoryStoreProtocol, MessageStoreProtocol
{
    private let timeline: any TimelinePersistenceProtocol
    private let memory: any MemoryStoreProtocol
    private let messages: any MessageStoreProtocol

    init(_ persistence: any TimelinePersistenceProtocol & MemoryStoreProtocol & MessageStoreProtocol) {
        timeline = persistence
        memory = persistence
        messages = persistence
    }

    nonisolated var isDurable: Bool { timeline.isDurable }

    func saveThread(_ thread: Thread) async throws { try await timeline.saveTimeline(thread) }
    func fetchThread(id: UUID) async throws -> Thread? { try await timeline.fetchTimeline(id: id) }
    func fetchAllThreads(includeArchived: Bool) async throws -> [Thread] {
        try await timeline.fetchAllTimelines(includeArchived: includeArchived)
    }
    func deleteThread(id: UUID) async throws { try await timeline.deleteTimeline(id: id) }
    func pruneThreads(
        olderThan timeInterval: TimeInterval,
        excluding excludedThreadIDs: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        try await timeline.pruneTimelines(
            olderThan: timeInterval,
            excluding: excludedThreadIDs,
            dryRun: dryRun
        )
    }

    func saveMemory(_ memory: Memory, policy: MemorySavePolicy) async throws -> UUID {
        try await self.memory.saveMemory(memory, policy: policy)
    }
    func fetchMemory(id: UUID) async throws -> Memory? { try await memory.fetchMemory(id: id) }
    func fetchAllMemories() async throws -> [Memory] { try await memory.fetchAllMemories() }
    func searchMemories(query: String) async throws -> [Memory] {
        try await memory.searchMemories(query: query)
    }
    func searchMemories(
        embedding: [Double], limit: Int, minSimilarity: Double
    ) async throws -> [(memory: Memory, similarity: Double)] {
        try await memory.searchMemories(
            embedding: embedding, limit: limit, minSimilarity: minSimilarity
        )
    }
    func searchMemories(matchingAnyTag tags: [String]) async throws -> [Memory] {
        try await memory.searchMemories(matchingAnyTag: tags)
    }
    func deleteMemory(id: UUID) async throws { try await memory.deleteMemory(id: id) }
    func updateMemory(_ memory: Memory) async throws { try await self.memory.updateMemory(memory) }
    func updateMemoryEmbedding(id: UUID, newEmbedding: [Double]) async throws {
        try await memory.updateMemoryEmbedding(id: id, newEmbedding: newEmbedding)
    }
    func vacuumMemories(threshold: Double) async throws -> Int {
        try await memory.vacuumMemories(threshold: threshold)
    }
    func pruneMemories(matching query: String, dryRun: Bool) async throws -> Int {
        try await memory.pruneMemories(matching: query, dryRun: dryRun)
    }
    func pruneMemories(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        try await memory.pruneMemories(olderThan: timeInterval, dryRun: dryRun)
    }

    func saveMessage(_ message: ConversationMessage) async throws {
        try await messages.saveMessage(message)
    }
    func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage] {
        try await messages.fetchMessages(for: timelineId)
    }
    func deleteMessages(for timelineId: UUID) async throws {
        try await messages.deleteMessages(for: timelineId)
    }
    func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        try await messages.pruneMessages(olderThan: timeInterval, dryRun: dryRun)
    }
    func fetchSnapshots(for timelineId: UUID) async throws -> [TurnSnapshot] {
        try await messages.fetchSnapshots(for: timelineId)
    }
}

/// Deprecated v3 spelling for the in-memory thread persistence.
@available(*, deprecated, renamed: "InMemoryThreadPersistence", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias InMemoryTimelinePersistence = InMemoryThreadPersistence

/// Deprecated v3 spelling for the canonical thread manager.
@available(*, deprecated, renamed: "ThreadManager", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelineManager = ThreadManager

/// Deprecated v3 spelling for the canonical thread driver.
@available(*, deprecated, renamed: "ThreadDriver", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelineDriver = ThreadDriver

/// Deprecated v3 spelling for the canonical manager error.
@available(*, deprecated, renamed: "ThreadError", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelineError = ThreadError

/// Deprecated v3 spelling for the canonical deletion result.
@available(*, deprecated, renamed: "ThreadDeletionResult", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelineDeletionResult = ThreadDeletionResult

/// Deprecated v3 spelling for the canonical archiver.
@available(*, deprecated, renamed: "ThreadArchiver", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelineArchiver = ThreadArchiver

/// Deprecated v3 spelling for the canonical task registry.
@available(*, deprecated, renamed: "ThreadTaskRegistry", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelineTaskRegistry = ThreadTaskRegistry

/// Deprecated v3 spelling for the canonical tool registry.
@available(*, deprecated, renamed: "ThreadToolRegistry", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelineToolRegistry = ThreadToolRegistry

/// Deprecated v3 spelling for the canonical prompt history.
@available(*, deprecated, renamed: "ThreadPromptHistory", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelinePromptHistory = ThreadPromptHistory

/// Deprecated v3 spelling for the canonical prompt journal registry.
@available(*, deprecated, renamed: "ThreadPromptJournals", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelinePromptJournals = ThreadPromptJournals

/// Deprecated v3 spelling for the canonical prompt history error.
@available(*, deprecated, renamed: "ThreadPromptHistoryError", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelinePromptHistoryError = ThreadPromptHistoryError

/// Deprecated v3 spelling for the canonical prompt context.
@available(*, deprecated, renamed: "ThreadContext", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelineContext = ThreadContext

/// Deprecated v3 spelling for the canonical list tool.
@available(*, deprecated, renamed: "ThreadListTool", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelineListTool = ThreadListTool

/// Deprecated v3 spelling for the canonical peek tool.
@available(*, deprecated, renamed: "ThreadPeekTool", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelinePeekTool = ThreadPeekTool

/// Deprecated v3 spelling for the canonical send tool.
@available(*, deprecated, renamed: "ThreadSendTool", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias TimelineSendTool = ThreadSendTool

public extension ThreadListTool {
    /// Deprecated v3 initializer spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    @_disfavoredOverload
    init(timelineStore: any TimelinePersistenceProtocol) {
        self.init(threadStore: LegacyTimelinePersistenceAdapter(timelineStore))
    }
}

public extension ThreadPeekTool {
    /// Deprecated v3 initializer spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    @_disfavoredOverload
    init(messageStore: any MessageStoreProtocol, timelineStore: any TimelinePersistenceProtocol) {
        self.init(
            messageStore: messageStore,
            threadStore: LegacyTimelinePersistenceAdapter(timelineStore)
        )
    }
}

public extension ThreadSendTool {
    /// Deprecated v3 initializer spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    @_disfavoredOverload
    init(
        messageStore: any MessageStoreProtocol,
        timelineStore: any TimelinePersistenceProtocol,
        agentInstanceId: UUID,
        sourceTimelineId: UUID
    ) {
        self.init(
            messageStore: messageStore,
            threadStore: LegacyTimelinePersistenceAdapter(timelineStore),
            agentInstanceID: agentInstanceId,
            sourceThreadID: sourceTimelineId
        )
    }
}

public extension ToolRouter {
    /// Deprecated v3 initializer spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    @_disfavoredOverload
    init(
        timelineManager: ThreadManager,
        messageStore: any MessageStoreProtocol,
        toolExecutionTimeout: TimeInterval = 60,
        approvalPolicy: any ToolApprovalPolicy = DenyAllToolApprovalPolicy(),
        sleep: (@Sendable (UInt64) async throws -> Void)? = nil,
        loggingConfiguration: LoggingConfiguration = .default
    ) {
        self.init(
            threadManager: timelineManager,
            messageStore: messageStore,
            toolExecutionTimeout: toolExecutionTimeout,
            approvalPolicy: approvalPolicy,
            sleep: sleep,
            loggingConfiguration: loggingConfiguration
        )
    }

    /// Deprecated v3 execution label.
    @available(*, deprecated, renamed: "execute(tool:arguments:threadID:availableTools:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    @_disfavoredOverload
    func execute(
        tool: ToolReference,
        arguments: [String: AnyCodable],
        timelineId: UUID,
        availableTools: [AnyTool]? = nil
    ) async throws -> ToolExecutionOutcome {
        try await execute(
            tool: tool,
            arguments: arguments,
            threadID: timelineId,
            availableTools: availableTools
        )
    }
}

public extension ThreadManager.RuntimeToolPolicy {
    /// Deprecated v3 initializer spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    @_disfavoredOverload
    init(
        installFilesystemTools: Bool = true,
        installTimelineObservationTools: Bool = true,
        installTimelineSendTool: Bool = true
    ) {
        self.init(
            installFilesystemTools: installFilesystemTools,
            installThreadObservationTools: installTimelineObservationTools,
            installThreadSendTool: installTimelineSendTool
        )
    }

    /// Deprecated v3 policy member.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    var installTimelineObservationTools: Bool { installThreadObservationTools }

    /// Deprecated v3 policy member.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    var installTimelineSendTool: Bool { installThreadSendTool }
}

public extension ThreadManager.Stores {
    /// Deprecated v3 initializer spelling. The legacy store is adapted once at the boundary.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    init(
        timelineStore: any TimelinePersistenceProtocol,
        messageStore: any MessageStoreProtocol,
        workspaceStore: any WorkspaceStore,
        toolPersistence: any ToolPersistenceProtocol,
        memoryStore: any MemoryStoreProtocol = InMemoryMemoryStore()
    ) {
        self.init(
            threadStore: LegacyTimelinePersistenceAdapter(timelineStore),
            messageStore: messageStore,
            workspaceStore: workspaceStore,
            toolPersistence: toolPersistence,
            memoryStore: memoryStore
        )
    }

    /// Deprecated v3 store member. The adapter preserves the old persistence protocol.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    var timelineStore: any TimelinePersistenceProtocol {
        ThreadPersistenceCompatibilityAdapter(threadStore)
    }
}

public extension ThreadManager {
    /// Deprecated v3 manager store member.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    var timelineStore: any TimelinePersistenceProtocol {
        ThreadPersistenceCompatibilityAdapter(threadStore)
    }

    /// Deprecated v3 manager operation.
    @available(*, deprecated, renamed: "createThread(title:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func createTimeline(title: String = "New Conversation") async throws -> Thread {
        try await createThread(title: title)
    }

    /// Deprecated v3 manager operation.
    @available(*, deprecated, renamed: "ensureThreadExists(id:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func ensureTimelineExists(id: UUID) async throws {
        try await ensureThreadExists(id: id)
    }

    /// Deprecated v3 manager operation.
    @available(*, deprecated, renamed: "hydrateThread(id:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func hydrateTimeline(id: UUID) async throws {
        try await hydrateThread(id: id)
    }

    /// Deprecated v3 manager operation.
    @available(*, deprecated, renamed: "updateThreadTitle(_:title:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func updateTimelineTitle(id: UUID, title: String) async throws {
        try await updateThreadTitle(id, title: title)
    }

    /// Deprecated v3 manager operation.
    @available(*, deprecated, renamed: "evictThreadFromMemory(id:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func evictTimelineFromMemory(id: UUID) async {
        await evictThreadFromMemory(id: id)
    }

    /// Deprecated v3 manager operation.
    @available(*, deprecated, renamed: "deleteThread(id:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func deleteTimeline(id: UUID) async {
        await deleteThread(id: id)
    }

    /// Deprecated v3 manager operation.
    @available(*, deprecated, renamed: "deleteThreadPermanently(id:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func deleteTimelinePermanently(id: UUID) async -> ThreadDeletionResult {
        await deleteThreadPermanently(id: id)
    }

    /// Deprecated v3 manager operation.
    @available(*, deprecated, renamed: "cleanupStaleThreads(maxAge:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func cleanupStaleTimelines(maxAge: TimeInterval) async {
        await cleanupStaleThreads(maxAge: maxAge)
    }

    /// Deprecated v3 manager operation.
    @available(*, deprecated, renamed: "thread(id:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func timeline(id: UUID) -> Thread? {
        thread(id: id)
    }

    /// Deprecated v3 manager operation.
    @available(*, deprecated, renamed: "touchThread(id:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func touchTimeline(id: UUID) {
        touchThread(id: id)
    }

    /// Deprecated v3 manager operation.
    @available(*, deprecated, renamed: "listThreads()", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func listTimelines() async throws -> [Thread] {
        try await listThreads()
    }

    /// Deprecated v3 parameter label.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func gatherExtensionSections(
        timelineId: UUID,
        agentInstanceId: UUID?,
        message: String
    ) async -> [any Prompt] {
        await gatherExtensionSections(
            threadID: timelineId,
            agentInstanceId: agentInstanceId,
            message: message
        )
    }
}

/// Deprecated v3 agent-instance query spelling retained as a one-way compatibility shim.
public extension AgentInstanceStoreProtocol {
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func fetchTimelines(attachedToAgent agentInstanceId: UUID) async throws -> [Thread] {
        try await fetchThreads(attachedToAgent: agentInstanceId)
    }
}
