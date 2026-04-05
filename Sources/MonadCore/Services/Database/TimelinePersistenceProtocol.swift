import MonadShared

// Protocol for managing conversation timeline lifecycle and metadata.

import Foundation

public protocol TimelinePersistenceProtocol: Sendable {
    func saveTimeline(_ session: Timeline) async throws
    func fetchTimeline(id: UUID) async throws -> Timeline?
    func fetchAllTimelines(includeArchived: Bool) async throws -> [Timeline]
    func deleteTimeline(id: UUID) async throws
    func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIds: [UUID],
        dryRun: Bool
    ) async throws -> Int
}
