import PKShared
import PositronicKit
import Foundation

public final class MockTimelinePersistence: TimelinePersistenceProtocol, @unchecked Sendable {
    private let backing = InMemoryTimelinePersistence()

    public var timelines: [Timeline] {
        get { (try? BlockingAsync.run { [self] in await self.backing.allTimelines() }) ?? [] }
        set { _ = try? BlockingAsync.run { [self] in await self.backing.replaceTimelines(newValue) } }
    }

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

    public func pruneTimelines(olderThan timeInterval: TimeInterval, excluding excludedTimelineIds: [UUID], dryRun: Bool) async throws -> Int {
        return 0
    }
}
