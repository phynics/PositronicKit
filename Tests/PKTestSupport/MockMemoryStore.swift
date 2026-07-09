import Foundation
import PKShared
import PositronicKit

/// In-memory `MemoryStoreProtocol` test double backed by a plain array.
///
/// Configurable/inspectable: `memories` (the backing store — seed or assert on it
/// directly) and `searchResults` (the fixed result set returned by the embedding-based
/// `searchMemories(embedding:limit:minSimilarity:)` overload, since a real similarity
/// search isn't performed). Text/tag-based search overloads filter `memories` directly.
/// Vacuum/prune operations are no-ops that report zero affected rows.
public final class MockMemoryStore: MemoryStoreProtocol, @unchecked Sendable {
    public var memories: [Memory] = []
    public var searchResults: [(memory: Memory, similarity: Double)] = []

    public init() {}

    public func saveMemory(_ memory: Memory, policy _: MemorySavePolicy) async throws -> UUID {
        memories.append(memory)
        return memory.id
    }

    public func fetchMemory(id: UUID) async throws -> Memory? {
        return memories.first(where: { $0.id == id })
    }

    public func fetchAllMemories() async throws -> [Memory] {
        return memories
    }

    public func hasAnyMemory() async throws -> Bool {
        !memories.isEmpty || !searchResults.isEmpty
    }

    public func searchMemories(query: String) async throws -> [Memory] {
        return memories.filter { $0.title.contains(query) || $0.content.contains(query) }
    }

    public func searchMemories(embedding _: [Double], limit _: Int, minSimilarity _: Double) async throws -> [(memory: Memory, similarity: Double)] {
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

    public func vacuumMemories(threshold _: Double) async throws -> Int {
        return 0
    }

    public func pruneMemories(matching _: String, dryRun _: Bool) async throws -> Int {
        return 0
    }

    public func pruneMemories(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        return 0
    }
}
