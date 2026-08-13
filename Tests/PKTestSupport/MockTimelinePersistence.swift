import Foundation
import PKShared
import PKUtilities
import PositronicKit
import struct PositronicKit.Thread
import Synchronization

/// In-memory `TimelinePersistenceProtocol` test double backed by a mutex-guarded array.
///
/// Inspectable: `timelines` reads/writes the backing store directly. `fetchAllTimelines`
/// filters out archived timelines unless `includeArchived` is `true`. `pruneTimelines`
/// is a no-op that always reports zero pruned rows.
@available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public final class MockTimelinePersistence: TimelinePersistenceProtocol, @unchecked Sendable {
    private let timelinesState = Mutex<[Timeline]>([])

    public var timelines: [Timeline] {
        get { timelinesState.withLock { $0 } }
        set { timelinesState.withLock { $0 = newValue } }
    }

    public init() {}

    public func saveTimeline(_ timeline: Timeline) async throws {
        timelinesState.withLock {
            if let index = $0.firstIndex(where: { $0.id == timeline.id }) {
                $0[index] = timeline
            } else {
                $0.append(timeline)
            }
        }
    }

    public func fetchTimeline(id: UUID) async throws -> Timeline? {
        timelinesState.withLock {
            $0.first { $0.id == id }
        }
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [Timeline] {
        timelinesState.withLock {
            includeArchived ? $0 : $0.filter { !$0.isArchived }
        }
    }

    public func deleteTimeline(id: UUID) async throws {
        timelinesState.withLock {
            $0.removeAll { $0.id == id }
        }
    }

    public func pruneTimelines(olderThan _: TimeInterval, excluding _: [UUID], dryRun _: Bool) async throws -> Int {
        return 0
    }
}

/// Canonical actor test double for `ThreadPersistenceProtocol` compatibility coverage.
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

/// Legacy actor test double used to prove v3 stores remain directly injectable.
@available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public actor MockLegacyTimelinePersistence: TimelinePersistenceProtocol {
    private let backing = MockTimelinePersistence()

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
