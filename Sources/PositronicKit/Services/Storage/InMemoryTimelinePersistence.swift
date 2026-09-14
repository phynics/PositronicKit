import Foundation
import PKContracts
import PKUtilities

/// Timeline-safe in-memory persistence for prototyping and development.
public actor InMemoryTimelinePersistence: TimelinePersistenceProtocol {
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

    package func allTimelines() -> [TimelineRecord] {
        timelines
    }

    package func replaceTimelines(_ timelines: [TimelineRecord]) {
        self.timelines = timelines
    }

}
