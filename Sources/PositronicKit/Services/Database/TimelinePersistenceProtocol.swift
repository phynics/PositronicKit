import PKContracts
import PKUtilities

// Protocol for managing timeline lifecycle and metadata.

import Foundation

public protocol TimelinePersistenceProtocol: DurabilityAware {
    func saveTimeline(_ timeline: TimelineRecord) async throws
    func fetchTimeline(id: UUID) async throws -> TimelineRecord?
    func fetchAllTimelines(includeArchived: Bool) async throws -> [TimelineRecord]
    func deleteTimeline(id: UUID) async throws
}
