import Foundation

/// Deprecated v3 spelling for ``Thread``.
@available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
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

/// Deprecated v3 spelling for the in-memory thread persistence.
@available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias InMemoryTimelinePersistence = InMemoryThreadPersistence

/// Deprecated v3 agent-instance query spelling retained as a one-way compatibility shim.
public extension AgentInstanceStoreProtocol {
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func fetchTimelines(attachedToAgent agentInstanceId: UUID) async throws -> [Thread] {
        try await fetchThreads(attachedToAgent: agentInstanceId)
    }
}
