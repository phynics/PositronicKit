import PKContracts
import PKUtilities

// Protocol for managing timeline lifecycle and metadata.

import Foundation

public protocol TimelinePersistenceProtocol: DurabilityAware {
    func saveTimeline(_ timeline: TimelineRecord) async throws
    func fetchTimeline(id: UUID) async throws -> TimelineRecord?
    func fetchAllTimelines(includeArchived: Bool) async throws -> [TimelineRecord]
    func deleteTimeline(id: UUID) async throws
    /// Deletes (or previews deleting) timelines older than `timeInterval`, skipping any timeline
    /// whose id appears in `excludedTimelineIDs`.
    ///
    /// - Parameters:
    ///   - timeInterval: Timelines older than this age (relative to now) are eligible for
    ///     pruning.
    ///   - excludedTimelineIDs: Timelines that must never be pruned regardless of age (e.g. the
    ///     active timeline).
    ///   - dryRun: When `true`, no rows are deleted; the store only computes and returns how many
    ///     rows *would* be deleted. When `false`, matching rows are actually deleted.
    /// - Returns: The count of rows deleted (`dryRun == false`) or that would be deleted
    ///   (`dryRun == true`). The returned `Int` has the same meaning in both modes, so a caller
    ///   can preview with `dryRun: true` and expect the same count from a following
    ///   `dryRun: false` call, provided the underlying data hasn't changed in between.
    /// - Note: Conformers must not mutate persisted state when `dryRun == true`. Side effects that
    ///   don't affect persisted rows (e.g. logging the preview) are permitted in dry-run mode.
    func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIDs: [UUID],
        dryRun: Bool
    ) async throws -> Int
}
