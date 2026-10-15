import Foundation
import PKContracts

/// Stateful Timeline entry points exposed by ``PKRuntime``.
public struct TimelineCapability: Sendable {
    private let timelineManager: TimelineManager
    private let agentManager: AgentManager
    private let messageStore: any TimelineMessageStoreProtocol
    private let turnEngine: TurnEngine
    private let runtime: PKRuntime

    init(
        timelineManager: TimelineManager,
        agentManager: AgentManager,
        messageStore: any TimelineMessageStoreProtocol,
        turnEngine: TurnEngine,
        runtime: PKRuntime
    ) {
        self.timelineManager = timelineManager
        self.agentManager = agentManager
        self.messageStore = messageStore
        self.turnEngine = turnEngine
        self.runtime = runtime
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
    ///
    /// For an ephemeral Timeline the returned handle joins that Timeline's lifetime: the runtime
    /// deletes the Timeline once the last handed-out handle is released.
    public func open(_ timelineID: UUID) -> TimelineHandle {
        TimelineHandle(
            timelineID: timelineID,
            engine: turnEngine,
            ephemeralToken: runtime.ephemeralRegistry.token(for: timelineID)
        )
    }

    /// Clones a Timeline's session into a detached, private, ephemeral Timeline in this runtime.
    ///
    /// The fork is an ordinary Timeline in the runtime's own repository: it carries no attached
    /// Agent, is marked private and ephemeral, and records `forkedFrom` lineage. Its semantic
    /// message history is copied with fresh message IDs, with `parentID` remapped to the clone's
    /// ancestors, so writing to the fork never touches the source Timeline. Turns, tool intents,
    /// and tool results are not copied: the fork is a new session, not a replay of the source's
    /// ledger.
    ///
    /// The returned handle starts direct Turns through
    /// ``TimelineHandle/startDirectTurn(_:context:options:)``. The fork supplies no tools of its
    /// own; pass the tools the Turn should be limited to through ``TurnOptions/tools``, for
    /// example ``RuntimeToolSets/readOnlyFilesystem(root:)``. The runtime deletes the ephemeral
    /// Timeline and its messages when the last handle is released, after any Turn still in flight
    /// finishes.
    ///
    /// - Parameters:
    ///   - timelineID: The source Timeline to clone.
    ///   - title: The fork's title, or `nil` to derive one from the source title.
    /// - Returns: A handle for the fork's ephemeral Timeline.
    /// - Throws: ``TimelineError/timelineNotFound`` when no Timeline has `timelineID`.
    public func fork(from timelineID: UUID, title: String? = nil) async throws -> TimelineHandle {
        await timelineManager.ensureEphemeralSweepStarted()
        await timelineManager.awaitEphemeralSweep()

        guard let source = try await timelineManager.timelineStore.fetchTimeline(id: timelineID) else {
            throw TimelineError.timelineNotFound
        }
        let sourceMessages = try await messageStore.fetchMessages(for: timelineID)

        let now = Date()
        let forkTimelineID = UUID()
        let forkRecord = TimelineRecord(
            id: forkTimelineID,
            title: title ?? "Fork of \(source.title)",
            createdAt: now,
            updatedAt: now,
            attachedAgentID: nil,
            isPrivate: true,
            isEphemeral: true,
            forkedFrom: TimelineForkOrigin(
                timelineID: source.id,
                throughMessageID: sourceMessages.last?.id,
                at: now
            )
        )
        try await timelineManager.timelineStore.saveTimeline(forkRecord)

        var messageIDMap: [UUID: UUID] = [:]
        for message in sourceMessages {
            let clone = TimelineMessage(
                id: UUID(),
                timelineID: forkTimelineID,
                role: message.messageRole,
                content: message.messageContent,
                timestamp: message.timestamp,
                parentID: message.parentID.flatMap { messageIDMap[$0] },
                reasoning: message.reasoning,
                toolCalls: message.toolCalls,
                toolCallID: message.toolCallID,
                agentID: message.agentID,
                executionKind: message.executionKind,
                remoteDepth: message.remoteDepth,
                snapshotData: message.snapshotData,
                status: message.status
            )
            messageIDMap[message.id] = clone.id
            try await messageStore.saveMessage(clone)
        }

        runtime.ephemeralRegistry.register(timelineID: forkTimelineID) { [timelineManager] id in
            await timelineManager.releaseEphemeralTimeline(id: id)
        }
        return open(forkTimelineID)
    }

    /// Lists persisted Timelines.
    ///
    /// Ephemeral Timelines are excluded unless `includeEphemeral` is `true`; they are private
    /// fork sessions owned by live handles, not durable history.
    public func list(
        includeArchived: Bool = true,
        includeEphemeral: Bool = false
    ) async throws -> [TimelineRecord] {
        let timelines = try await timelineManager.timelineStore
            .fetchAllTimelines(includeArchived: includeArchived)
        guard !includeEphemeral else { return timelines }
        return timelines.filter { !$0.isEphemeral }
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
