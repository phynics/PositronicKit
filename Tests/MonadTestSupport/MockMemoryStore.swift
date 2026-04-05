import MonadShared
import MonadCore
import Foundation

public final class MockMemoryStore: MemoryStoreProtocol, @unchecked Sendable {
    public var memories: [Memory] = []
    public var searchResults: [(memory: Memory, similarity: Double)] = []

    public init() {}

    public func saveMemory(_ memory: Memory, policy: MemorySavePolicy) async throws -> UUID {
        memories.append(memory)
        return memory.id
    }

    public func fetchMemory(id: UUID) async throws -> Memory? {
        return memories.first(where: { $0.id == id })
    }

    public func fetchAllMemories() async throws -> [Memory] {
        return memories
    }

    public func searchMemories(query: String) async throws -> [Memory] {
        return memories.filter { $0.title.contains(query) || $0.content.contains(query) }
    }

    public func searchMemories(embedding: [Double], limit: Int, minSimilarity: Double) async throws -> [(memory: Memory, similarity: Double)] {
        return searchResults
    }

    public func searchMemories(matchingAnyTag tags: [String]) async throws -> [Memory] {
        return memories.filter { memory in
            !Set(memory.tagArray).intersection(tags).isEmpty
        }
    }

    public func deleteMemory(id: UUID) async throws {
        memories.removeAll(where: { $0.id == id })
    }

    public func updateMemory(_ memory: Memory) async throws {
        if let index = memories.firstIndex(where: { $0.id == memory.id }) {
            memories[index] = memory
        }
    }

    public func updateMemoryEmbedding(id: UUID, newEmbedding: [Double]) async throws {
        if let index = memories.firstIndex(where: { $0.id == id }) {
            var memory = memories[index]
            if let data = try? JSONEncoder().encode(newEmbedding) {
                memory.embedding = String(data: data, encoding: .utf8) ?? ""
                memories[index] = memory
            }
        }
    }

    public func vacuumMemories(threshold: Double) async throws -> Int {
        return 0
    }

    public func pruneMemories(matching query: String, dryRun: Bool) async throws -> Int {
        return 0
    }

    public func pruneMemories(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        return 0
    }
}
