import Foundation
import PKContracts

/// Stateful Timeline entry points exposed by ``PKRuntime``.
public struct TimelineCapability: Sendable {
    private let timelineManager: TimelineManager
    private let agentManager: AgentManager
    private let messageStore: any TimelineMessageStoreProtocol
    private let turnEngine: TurnEngine

    init(
        timelineManager: TimelineManager,
        agentManager: AgentManager,
        messageStore: any TimelineMessageStoreProtocol,
        turnEngine: TurnEngine
    ) {
        self.timelineManager = timelineManager
        self.agentManager = agentManager
        self.messageStore = messageStore
        self.turnEngine = turnEngine
    }

    /// Creates and persists a Timeline, returning its stable handle.
    ///
    /// When `agentID` is supplied, the Agent must be active. The operation validates the Agent
    /// before durable creation and returns only after the Timeline metadata row contains the attachment, so
    /// managed execution can begin immediately from the returned handle.
    ///
    /// - Parameters:
    ///   - title: The title to persist for the new Timeline.
    ///   - agentID: An existing Agent that owns the managed execution authority, if any.
    /// - Returns: A handle for the newly created Timeline.
    public func create(
        title: String = "New Timeline",
        attaching agentID: UUID? = nil
    ) async throws -> TimelineHandle {
        let timeline = if let agentID {
            try await agentManager.createTimeline(title: title, attaching: agentID)
        } else {
            try await timelineManager.createTimeline(title: title)
        }
        return open(timeline.id)
    }

    /// Opens a handle without performing persistence I/O.
    public func open(_ timelineID: UUID) -> TimelineHandle {
        TimelineHandle(timelineID: timelineID, engine: turnEngine)
    }

    /// Lists persisted Timelines.
    public func list(includeArchived: Bool = true) async throws -> [TimelineRecord] {
        try await timelineManager.timelineStore.fetchAllTimelines(includeArchived: includeArchived)
    }

    /// Reads one cached or persisted Timeline.
    public func get(_ timelineID: UUID) async throws -> TimelineRecord? {
        try await timelineManager.timelineStore.fetchTimeline(id: timelineID)
    }

    /// Reads durable Timeline messages in oldest-first order.
    ///
    /// An unknown Timeline ID returns an empty array. The result is durable Timeline history, not
    /// the assembled prompt state observed by `PKPrompt.PromptJournal`.
    public func messages(for timelineID: UUID) async throws -> [TimelineMessage] {
        try await messageStore.fetchMessages(for: timelineID)
    }

    /// Renames a Timeline while preserving its existing handle.
    public func rename(_ timelineID: UUID, to title: String) async throws {
        try await timelineManager.updateTimelineTitle(timelineID, title: title)
    }

    /// Attaches an ordinary Workspace to a Timeline.
    public func attachWorkspace(_ workspaceID: UUID, to timelineID: UUID) async throws {
        try await timelineManager.attachWorkspace(workspaceID, to: timelineID)
    }

    /// Detaches an ordinary Workspace from a Timeline.
    public func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws {
        try await timelineManager.detachWorkspace(workspaceID, from: timelineID)
    }
}
