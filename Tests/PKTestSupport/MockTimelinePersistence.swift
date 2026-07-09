import Foundation
import PKShared
import PositronicKit
import Synchronization

/// In-memory `TimelinePersistenceProtocol` test double backed by a mutex-guarded array.
///
/// Inspectable: `timelines` reads/writes the backing store directly. `fetchAllTimelines`
/// filters out archived timelines unless `includeArchived` is `true`. `pruneTimelines`
/// is a no-op that always reports zero pruned rows.
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
