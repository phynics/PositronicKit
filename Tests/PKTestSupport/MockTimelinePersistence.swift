import Foundation
import PKShared
import PKUtilities
import PositronicKit
import struct PositronicKit.Thread
import Synchronization

/// In-memory `ThreadPersistenceProtocol` test double backed by a mutex-guarded array.
///
/// Inspectable: `threads` reads/writes the backing store directly. `fetchAllThreads`
/// filters out archived threads unless `includeArchived` is `true`. `pruneThreads`
/// is a no-op that always reports zero pruned rows.
public final class MockThreadPersistenceStore: ThreadPersistenceProtocol, @unchecked Sendable {
    private let threadsState = Mutex<[Thread]>([])

    public var threads: [Thread] {
        get { threadsState.withLock { $0 } }
        set { threadsState.withLock { $0 = newValue } }
    }

    public init() {}

    public func saveThread(_ thread: Thread) async throws {
        threadsState.withLock {
            if let index = $0.firstIndex(where: { $0.id == thread.id }) {
                $0[index] = thread
            } else {
                $0.append(thread)
            }
        }
    }

    public func fetchThread(id: UUID) async throws -> Thread? {
        threadsState.withLock {
            $0.first { $0.id == id }
        }
    }

    public func fetchAllThreads(includeArchived: Bool) async throws -> [Thread] {
        threadsState.withLock {
            includeArchived ? $0 : $0.filter { !$0.isArchived }
        }
    }

    public func deleteThread(id: UUID) async throws {
        threadsState.withLock {
            $0.removeAll { $0.id == id }
        }
    }

    public func pruneThreads(olderThan _: TimeInterval, excluding _: [UUID], dryRun _: Bool) async throws -> Int {
        return 0
    }
}

/// Actor-backed canonical persistence test double used for compatibility coverage.
public actor MockThreadPersistence: ThreadPersistenceProtocol {
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
        includeArchived ? threads : threads.filter { !$0.isArchived }
    }

    public func deleteThread(id: UUID) async throws {
        threads.removeAll { $0.id == id }
    }

    public func pruneThreads(
        olderThan _: TimeInterval,
        excluding _: [UUID],
        dryRun _: Bool
    ) async throws -> Int {
        0
    }
}

extension MockThreadPersistenceStore: TimelinePersistenceProtocol {
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public func saveTimeline(_ timeline: Thread) async throws { try await saveThread(timeline) }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public func fetchTimeline(id: UUID) async throws -> Thread? { try await fetchThread(id: id) }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public func fetchAllTimelines(includeArchived: Bool) async throws -> [Thread] {
        try await fetchAllThreads(includeArchived: includeArchived)
    }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public func deleteTimeline(id: UUID) async throws { try await deleteThread(id: id) }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIds: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        try await pruneThreads(olderThan: timeInterval, excluding: excludedTimelineIds, dryRun: dryRun)
    }
}

/// Deprecated fixture spelling retained for tests that exercise the v3 persistence protocol.
@available(*, deprecated, renamed: "MockThreadPersistenceStore", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias MockTimelinePersistence = MockThreadPersistenceStore

/// Legacy actor test double used to prove v3 stores remain directly injectable.
@available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public actor MockLegacyTimelinePersistence: TimelinePersistenceProtocol {
    private let backing = MockThreadPersistenceStore()

    public init() {}

    public func saveTimeline(_ timeline: Timeline) async throws {
        try await backing.saveTimeline(timeline)
    }

    public func fetchTimeline(id: UUID) async throws -> Timeline? {
        try await backing.fetchTimeline(id: id)
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [Timeline] {
        try await backing.fetchAllTimelines(includeArchived: includeArchived)
    }

    public func deleteTimeline(id: UUID) async throws {
        try await backing.deleteTimeline(id: id)
    }

    public func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIds: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        try await backing.pruneTimelines(
            olderThan: timeInterval,
            excluding: excludedTimelineIds,
            dryRun: dryRun
        )
    }
}
