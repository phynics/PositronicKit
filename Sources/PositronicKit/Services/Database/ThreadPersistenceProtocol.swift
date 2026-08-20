import PKContracts
import PKUtilities

// Protocol for managing thread thread lifecycle and metadata.

import Foundation

public protocol ThreadPersistenceProtocol: DurabilityAware {
    func saveThread(_ thread: Thread) async throws
    func fetchThread(id: UUID) async throws -> Thread?
    func fetchAllThreads(includeArchived: Bool) async throws -> [Thread]
    func deleteThread(id: UUID) async throws
    /// Deletes (or previews deleting) threads older than `timeInterval`, skipping any thread
    /// whose id appears in `excludedThreadIDs`.
    ///
    /// - Parameters:
    ///   - timeInterval: Threads older than this age (relative to now) are eligible for
    ///     pruning.
    ///   - excludedThreadIDs: Threads that must never be pruned regardless of age (e.g. the
    ///     active thread).
    ///   - dryRun: When `true`, no rows are deleted; the store only computes and returns how many
    ///     rows *would* be deleted. When `false`, matching rows are actually deleted.
    /// - Returns: The count of rows deleted (`dryRun == false`) or that would be deleted
    ///   (`dryRun == true`). The returned `Int` has the same meaning in both modes, so a caller
    ///   can preview with `dryRun: true` and expect the same count from a following
    ///   `dryRun: false` call, provided the underlying data hasn't changed in between.
    /// - Note: Conformers must not mutate persisted state when `dryRun == true`. Side effects that
    ///   don't affect persisted rows (e.g. logging the preview) are permitted in dry-run mode.
    func pruneThreads(
        olderThan timeInterval: TimeInterval,
        excluding excludedThreadIDs: [UUID],
        dryRun: Bool
    ) async throws -> Int
}
