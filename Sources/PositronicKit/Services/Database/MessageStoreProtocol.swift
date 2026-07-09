import PKShared

// Protocol for managing chat history and message persistence.

import Foundation

public protocol MessageStoreProtocol: Sendable {
    func saveMessage(_ message: ConversationMessage) async throws
    func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage]
    func deleteMessages(for timelineId: UUID) async throws
    /// Deletes (or previews deleting) messages older than `timeInterval`.
    ///
    /// - Parameters:
    ///   - timeInterval: Messages older than this age (relative to now) are eligible for pruning.
    ///   - dryRun: When `true`, no rows are deleted; the store only computes and returns how many
    ///     rows *would* be deleted. When `false`, matching rows are actually deleted.
    /// - Returns: The count of rows deleted (`dryRun == false`) or that would be deleted
    ///   (`dryRun == true`). The returned `Int` has the same meaning in both modes, so a caller
    ///   can preview with `dryRun: true` and expect the same count from a following
    ///   `dryRun: false` call, provided the underlying data hasn't changed in between.
    /// - Note: Conformers must not mutate persisted state when `dryRun == true`. Side effects that
    ///   don't affect persisted rows (e.g. logging the preview) are permitted in dry-run mode.
    func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int
    func fetchSnapshots(for timelineId: UUID) async throws -> [TurnSnapshot]
}
