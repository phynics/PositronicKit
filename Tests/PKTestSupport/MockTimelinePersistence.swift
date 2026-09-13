import Foundation
import PKContracts
import PKUtilities
import PositronicKit
import Synchronization

/// In-memory `TimelinePersistenceProtocol` test double backed by a mutex-guarded array.
///
/// Inspectable: `timelines` reads/writes the backing store directly. `fetchAllTimelines`
/// filters out archived timelines unless `includeArchived` is `true`. `pruneTimelines`
/// is a no-op that always reports zero pruned rows.
public final class MockTimelinePersistenceStore: TimelinePersistenceProtocol, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    private let timelinesState = Mutex<[TimelineRecord]>([])

    public var timelines: [TimelineRecord] {
        get { timelinesState.withLock { $0 } }
        set { timelinesState.withLock { $0 = newValue } }
    }

    public init() {}

    public func saveTimeline(_ timeline: TimelineRecord) async throws {
        timelinesState.withLock {
            if let index = $0.firstIndex(where: { $0.id == timeline.id }) {
                $0[index] = timeline
            } else {
                $0.append(timeline)
            }
        }
    }

    public func fetchTimeline(id: UUID) async throws -> TimelineRecord? {
        timelinesState.withLock {
            $0.first { $0.id == id }
        }
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [TimelineRecord] {
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

/// Actor-backed canonical persistence test double used for compatibility coverage.
public actor MockTimelinePersistence: TimelinePersistenceProtocol {
    private var timelines: [TimelineRecord] = []

    public init() {}

    public func saveTimeline(_ timeline: TimelineRecord) async throws {
        if let index = timelines.firstIndex(where: { $0.id == timeline.id }) {
            timelines[index] = timeline
        } else {
            timelines.append(timeline)
        }
    }

    public func fetchTimeline(id: UUID) async throws -> TimelineRecord? {
        timelines.first { $0.id == id }
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [TimelineRecord] {
        includeArchived ? timelines : timelines.filter { !$0.isArchived }
    }

    public func deleteTimeline(id: UUID) async throws {
        timelines.removeAll { $0.id == id }
    }

    public func pruneTimelines(
        olderThan _: TimeInterval,
        excluding _: [UUID],
        dryRun _: Bool
    ) async throws -> Int {
        0
    }
}
