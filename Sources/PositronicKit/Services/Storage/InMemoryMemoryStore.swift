import Foundation
import PKContracts
import PKUtilities

/// Thread-safe in-memory memory store for prototyping and development.
public actor InMemoryMemoryStore: MemoryStoreProtocol {
    private var memories: [Memory] = []

    public init() {}

    public func saveMemory(_ memory: Memory, policy _: MemorySavePolicy) async throws -> UUID {
        memories.append(memory)
        return memory.id
    }

    public func fetchMemory(id: UUID) async throws -> Memory? {
        memories.first { $0.id == id }
    }

    public func fetchAllMemories() async throws -> [Memory] {
        memories
    }

    public func searchMemories(query: String) async throws -> [Memory] {
        memories.filter { $0.title.contains(query) || $0.content.contains(query) }
    }

    public func searchMemories(matchingAnyTag tags: [String]) async throws -> [Memory] {
        memories.filter { memory in
            !Set(memory.tagArray).intersection(tags).isEmpty
        }
    }

    public func deleteMemory(id: UUID) async throws {
        memories.removeAll { $0.id == id }
    }

    public func updateMemory(_ memory: Memory) async throws {
        if let index = memories.firstIndex(where: { $0.id == memory.id }) {
            memories[index] = memory
        }
    }

    public func vacuumMemories(threshold _: Double) async throws -> Int {
        0
    }

    public func pruneMemories(matching _: String, dryRun _: Bool) async throws -> Int {
        0
    }

    public func pruneMemories(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        0
    }
}
