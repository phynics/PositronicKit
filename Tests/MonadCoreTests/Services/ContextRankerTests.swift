import Testing
import Foundation
@testable import MonadCore
@testable import MonadShared

@Suite final class ContextRankerTests {
    var ranker: ContextRanker!

    init() {
        // super.setUp()
        ranker = ContextRanker()
    }

    func createMemory(id: UUID, title: String, content: String, tags: [String] = [], embedding: [Double], date: Date) -> Memory {
        return Memory(
            id: id,
            title: title,
            content: content,
            createdAt: date,
            updatedAt: date,
            tags: tags,
            metadata: [:],
            embedding: embedding
        )
    }

    @Test

    func testContextRankerTimeDecay() {
        let id1 = UUID()
        let id2 = UUID()
        let queryEmbedding = [1.0, 0.0]

        // Exact same memory content, tags, and embedding similarity
        let now = Date()
        let halfLife = now.addingTimeInterval(-42 * 86400) // 42 days old (0.5x decay factor)

        let memoryNew = createMemory(
            id: id1,
            title: "Docs",
            content: "Using the framework",
            embedding: [1.0, 0.0], // exact match
            date: now
        )

        let memoryOld = createMemory(
            id: id2,
            title: "Docs",
            content: "Using the framework",
            embedding: [1.0, 0.0], // exact match
            date: halfLife
        )

        let semanticResults = [
            SemanticSearchResult(memory: memoryOld, similarity: 1.0),
            SemanticSearchResult(memory: memoryNew, similarity: 1.0)
        ]

        let ranked = ranker.rankMemories(
            semantic: semanticResults,
            tagBased: [],
            queryEmbedding: queryEmbedding
        )

        #expect(ranked.count == 2)
        #expect(ranked[0].memory.id == id1) // Newest memory should win due to higher score
        #expect(abs((ranked[0].similarity ?? 0.0) - 1.0) < 0.0001)
        #expect(ranked[1].memory.id == id2)
        #expect(abs((ranked[1].similarity ?? 0.0) - 0.5) < 0.0001) // Decayed by 50%
    }

    @Test
    func testContextRankerTagBoosts() {
        let idSemantic = UUID()
        let idTag = UUID()
        let queryEmbedding = [1.0, 0.0]
        let now = Date()

        // Very similar semantic memory but not tagged
        let memorySemOnly = createMemory(
            id: idSemantic,
            title: "Code snippet",
            content: "print('hello')",
            embedding: [0.9, 0.0], // high similarity (0.9)
            date: now
        )

        // Weak semantic match but directly tagged by user query
        let memoryTagOnly = createMemory(
            id: idTag,
            title: "Python snippet",
            content: "print(1)",
            tags: ["python"], // Explicit tag
            embedding: [0.1, 0.0], // low similarity (0.1)
            date: now
        )

        let semanticResults = [
            SemanticSearchResult(memory: memorySemOnly, similarity: 0.9)
        ]

        // Simulate finding the tagged memory from a tag search, it adds `tagBoost: 0.5`
        // So the tagged memory effectively scores VectorMath.cosineSimilarity([1.0, 0.0], [0.1, 0.0]) + 0.5 = 1.0 + 0.5 = 1.5
        let ranked = ranker.rankMemories(
            semantic: semanticResults,
            tagBased: [memoryTagOnly],
            queryEmbedding: queryEmbedding
        )

        // The newly tagged memory with the tag boost (1.5) now ranks above the semantic one (0.9)
        #expect(ranked.count == 2)
        #expect(ranked[0].memory.id == idTag)
        #expect(abs((ranked[0].similarity ?? 0) - 1.5) < 0.0001)
        #expect(ranked[1].memory.id == idSemantic)
        #expect(abs((ranked[1].similarity ?? 0) - 0.9) < 0.0001)
    }

    @Test
    func testContextRankerTagBoostsOnExistingSemanticResult() {
        let idMerged = UUID()
        let queryEmbedding = [1.0, 0.0]
        let now = Date()

        let memoryMerged = createMemory(
            id: idMerged,
            title: "Docs",
            content: "The manual",
            tags: ["manual"],
            embedding: [0.8, 0.0], // Similarity 0.8
            date: now
        )

        let semanticResults = [
            SemanticSearchResult(memory: memoryMerged, similarity: 0.8)
        ]

        let ranked = ranker.rankMemories(
            semantic: semanticResults,
            tagBased: [memoryMerged],
            queryEmbedding: queryEmbedding
        )

        #expect(ranked.count == 1)
        // Score should be 0.8 + 0.5 (tag boost) = 1.3
        #expect(abs((ranked[0].similarity ?? 0) - 1.3) < 0.0001)
    }
}
