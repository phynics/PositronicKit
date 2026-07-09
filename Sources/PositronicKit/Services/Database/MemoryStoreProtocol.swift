import PKShared

// Protocol for managing semantic memories and vector search.

import Foundation

public protocol MemoryStoreProtocol: Sendable {
    func saveMemory(_ memory: Memory, policy: MemorySavePolicy) async throws -> UUID
    func fetchMemory(id: UUID) async throws -> Memory?
    func fetchAllMemories() async throws -> [Memory]
    func hasAnyMemory() async throws -> Bool
    func searchMemories(query: String) async throws -> [Memory]
    func searchMemories(
        embedding: [Double], limit: Int, minSimilarity: Double
    ) async throws -> [(memory: Memory, similarity: Double)]
    func searchMemories(matchingAnyTag tags: [String]) async throws -> [Memory]
    func deleteMemory(id: UUID) async throws
    func updateMemory(_ memory: Memory) async throws
    func updateMemoryEmbedding(id: UUID, newEmbedding: [Double]) async throws
    func vacuumMemories(threshold: Double) async throws -> Int
    /// Deletes (or previews deleting) memories matching `query`.
    ///
    /// - Parameters:
    ///   - query: Selection criteria for eligible memories (conformer-defined matching, e.g.
    ///     title/content substring or tag match).
    ///   - dryRun: When `true`, no rows are deleted; the store only computes and returns how many
    ///     rows *would* be deleted. When `false`, matching rows are actually deleted.
    /// - Returns: The count of rows deleted (`dryRun == false`) or that would be deleted
    ///   (`dryRun == true`). The returned `Int` has the same meaning in both modes, so a caller
    ///   can preview with `dryRun: true` and expect the same count from a following
    ///   `dryRun: false` call, provided the underlying data hasn't changed in between.
    /// - Note: Conformers must not mutate persisted state when `dryRun == true`. Side effects that
    ///   don't affect persisted rows (e.g. logging the preview) are permitted in dry-run mode.
    func pruneMemories(matching query: String, dryRun: Bool) async throws -> Int

    /// Deletes (or previews deleting) memories older than `timeInterval`.
    ///
    /// - Parameters:
    ///   - timeInterval: Memories older than this age (relative to now) are eligible for pruning.
    ///   - dryRun: When `true`, no rows are deleted; the store only computes and returns how many
    ///     rows *would* be deleted. When `false`, matching rows are actually deleted.
    /// - Returns: The count of rows deleted (`dryRun == false`) or that would be deleted
    ///   (`dryRun == true`). The returned `Int` has the same meaning in both modes, so a caller
    ///   can preview with `dryRun: true` and expect the same count from a following
    ///   `dryRun: false` call, provided the underlying data hasn't changed in between.
    /// - Note: Conformers must not mutate persisted state when `dryRun == true`. Side effects that
    ///   don't affect persisted rows (e.g. logging the preview) are permitted in dry-run mode.
    func pruneMemories(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int
}

public extension MemoryStoreProtocol {
    func hasAnyMemory() async throws -> Bool {
        try !(await fetchAllMemories()).isEmpty
    }
}
