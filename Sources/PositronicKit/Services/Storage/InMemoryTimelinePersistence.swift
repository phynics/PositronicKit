import Foundation
import PKShared
import PKUtilities

/// Thread-safe in-memory thread persistence for prototyping and development.
public actor InMemoryThreadPersistence: ThreadPersistenceProtocol, TimelinePersistenceProtocol {
    private var threads: [Thread] = []

    public init() {}

    public func saveThread(_ thread: Thread) async throws {
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[index] = thread
        } else {
            threads.append(thread)
        }
    }

    public func fetchThread(id: UUID) async throws -> Thread? {
        threads.first { $0.id == id }
    }

    public func fetchAllThreads(includeArchived: Bool) async throws -> [Thread] {
        if includeArchived {
            return threads
        } else {
            return threads.filter { !$0.isArchived }
        }
    }

    public func deleteThread(id: UUID) async throws {
        threads.removeAll { $0.id == id }
    }

    public func pruneThreads(olderThan _: TimeInterval, excluding _: [UUID], dryRun _: Bool) async throws -> Int {
        0
    }

    package func allThreads() -> [Thread] {
        threads
    }

    package func replaceThreads(_ threads: [Thread]) {
        self.threads = threads
    }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    package func allTimelines() -> [Thread] {
        threads
    }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    package func replaceTimelines(_ timelines: [Thread]) {
        threads = timelines
    }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public func saveTimeline(_ timeline: Thread) async throws {
        try await saveThread(timeline)
    }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public func fetchTimeline(id: UUID) async throws -> Thread? {
        try await fetchThread(id: id)
    }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public func fetchAllTimelines(includeArchived: Bool) async throws -> [Thread] {
        try await fetchAllThreads(includeArchived: includeArchived)
    }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public func deleteTimeline(id: UUID) async throws {
        try await deleteThread(id: id)
    }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIds: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        try await pruneThreads(olderThan: timeInterval, excluding: excludedTimelineIds, dryRun: dryRun)
    }
}
