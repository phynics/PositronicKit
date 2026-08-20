import Foundation
import PKContracts
import PKUtilities
import PositronicKit
import Synchronization

/// In-memory `MemoryStoreProtocol` test double backed by mutex-guarded state.
///
/// Configurable/inspectable: `memories` (the backing store — seed or assert on it
/// directly) and `searchResults` (the fixed result set returned by the embedding-based
/// `searchMemories(embedding:limit:minSimilarity:)` overload, since a real similarity
/// search isn't performed). Text/tag-based search overloads filter `memories` directly.
/// Vacuum/prune operations are no-ops that report zero affected rows. Each read/modify/write
/// operation is one mutex transaction, so concurrent saves and updates do not lose unrelated data.
public final class MockMemoryStore: MemoryStoreProtocol, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    private struct State: Sendable {
        var memories: [Memory] = []
        var searchResults: [(memory: Memory, similarity: Double)] = []
    }

    private let state = Mutex(State())

    public var memories: [Memory] {
        get { state.withLock { $0.memories } }
        set { state.withLock { $0.memories = newValue } }
    }

    public var searchResults: [(memory: Memory, similarity: Double)] {
        get { state.withLock { $0.searchResults } }
        set { state.withLock { $0.searchResults = newValue } }
    }

    public init() {}

    public func saveMemory(_ memory: Memory, policy _: MemorySavePolicy) async throws -> UUID {
        state.withLock { $0.memories.append(memory) }
        return memory.id
    }

    public func fetchMemory(id: UUID) async throws -> Memory? {
        state.withLock { $0.memories.first(where: { $0.id == id }) }
    }

    public func fetchAllMemories() async throws -> [Memory] {
        state.withLock { $0.memories }
    }

    public func hasAnyMemory() async throws -> Bool {
        state.withLock { !$0.memories.isEmpty || !$0.searchResults.isEmpty }
    }

    public func searchMemories(query: String) async throws -> [Memory] {
        state.withLock {
            $0.memories.filter { $0.title.contains(query) || $0.content.contains(query) }
        }
    }

    public func searchMemories(embedding _: [Double], limit _: Int, minSimilarity _: Double) async throws -> [(memory: Memory, similarity: Double)] {
        state.withLock { $0.searchResults }
    }

    public func searchMemories(matchingAnyTag tags: [String]) async throws -> [Memory] {
        state.withLock {
            $0.memories.filter { memory in
                !Set(memory.tagArray).intersection(tags).isEmpty
            }
        }
    }

    public func deleteMemory(id: UUID) async throws {
        state.withLock { $0.memories.removeAll(where: { $0.id == id }) }
    }

    public func updateMemory(_ memory: Memory) async throws {
        state.withLock {
            if let index = $0.memories.firstIndex(where: { $0.id == memory.id }) {
                $0.memories[index] = memory
            }
        }
    }

    public func updateMemoryEmbedding(id: UUID, newEmbedding: [Double]) async throws {
        guard
            let data = try? JSONEncoder().encode(newEmbedding),
            let encodedEmbedding = String(data: data, encoding: .utf8)
        else {
            return
        }

        state.withLock {
            if let index = $0.memories.firstIndex(where: { $0.id == id }) {
                var memory = $0.memories[index]
                memory.embedding = encodedEmbedding
                $0.memories[index] = memory
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
