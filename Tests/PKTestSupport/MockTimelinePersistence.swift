import PKShared
import PositronicKit
import Foundation
import Synchronization

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

    public func pruneTimelines(olderThan timeInterval: TimeInterval, excluding excludedTimelineIds: [UUID], dryRun: Bool) async throws -> Int {
        return 0
    }
}
