import MonadShared

// Protocol for managing semantic memories and vector search.

import Foundation

public protocol MemoryStoreProtocol: Sendable {
    func saveMemory(_ memory: Memory, policy: MemorySavePolicy) async throws -> UUID
    func fetchMemory(id: UUID) async throws -> Memory?
    func fetchAllMemories() async throws -> [Memory]
    func searchMemories(query: String) async throws -> [Memory]
    func searchMemories(
        embedding: [Double], limit: Int, minSimilarity: Double
    ) async throws -> [(memory: Memory, similarity: Double)]
    func searchMemories(matchingAnyTag tags: [String]) async throws -> [Memory]
    func deleteMemory(id: UUID) async throws
    func updateMemory(_ memory: Memory) async throws
    func updateMemoryEmbedding(id: UUID, newEmbedding: [Double]) async throws
    func vacuumMemories(threshold: Double) async throws -> Int
    func pruneMemories(matching query: String, dryRun: Bool) async throws -> Int
    func pruneMemories(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int
}
