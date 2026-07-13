import Foundation
import PKShared
import PKUtilities

/// Thread-safe in-memory timeline persistence for prototyping and development.
public actor InMemoryTimelinePersistence: TimelinePersistenceProtocol {
    private var timelines: [Timeline] = []

    public init() {}

    public func saveTimeline(_ timeline: Timeline) async throws {
        if let index = timelines.firstIndex(where: { $0.id == timeline.id }) {
            timelines[index] = timeline
        } else {
            timelines.append(timeline)
        }
    }

    public func fetchTimeline(id: UUID) async throws -> Timeline? {
        timelines.first { $0.id == id }
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [Timeline] {
        if includeArchived {
            return timelines
        } else {
            return timelines.filter { !$0.isArchived }
        }
    }

    public func deleteTimeline(id: UUID) async throws {
        timelines.removeAll { $0.id == id }
    }

    public func pruneTimelines(olderThan _: TimeInterval, excluding _: [UUID], dryRun _: Bool) async throws -> Int {
        0
    }

    package func allTimelines() -> [Timeline] {
        timelines
    }

    package func replaceTimelines(_ timelines: [Timeline]) {
        self.timelines = timelines
    }
}
