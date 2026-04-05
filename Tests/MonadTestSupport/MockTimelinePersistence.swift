import MonadShared
import MonadCore
import Foundation

public final class MockTimelinePersistence: TimelinePersistenceProtocol, @unchecked Sendable {
    public var timelines: [Timeline] = []

    public init() {}

    public func saveTimeline(_ timeline: Timeline) async throws {
        if let index = timelines.firstIndex(where: { $0.id == timeline.id }) {
            timelines[index] = timeline
        } else {
            timelines.append(timeline)
        }
    }

    public func fetchTimeline(id: UUID) async throws -> Timeline? {
        return timelines.first(where: { $0.id == id })
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [Timeline] {
        if includeArchived {
            return timelines
        } else {
            return timelines.filter { !$0.isArchived }
        }
    }

    public func deleteTimeline(id: UUID) async throws {
        timelines.removeAll(where: { $0.id == id })
    }

    public func pruneTimelines(olderThan timeInterval: TimeInterval, excluding excludedTimelineIds: [UUID], dryRun: Bool) async throws -> Int {
        return 0
    }
}
