import Testing
import Foundation
@testable import MonadCore
@testable import MonadShared
import MonadTestSupport
@Suite struct MockVectorStoreTests {

    @Test("Mock Store Initialize and Add")
    func testMockStoreBasics() async throws {
        let store = MockVectorStore()
        try await store.initialize()

        let vectors: [[Float]] = [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0]
        ]
        let keys: [UInt64] = [1, 2]

        try await store.add(vectors: vectors, keys: keys)

        let count = await store.count
        #expect(count == 2)
    }

    @Test("Mock Store Search")
    func testMockStoreSearch() async throws {
        let store = MockVectorStore()
        let vectors: [[Float]] = [
            [1.0, 0.0, 0.0, 0.0], // Key 1
            [0.0, 1.0, 0.0, 0.0]  // Key 2
        ]
        let keys: [UInt64] = [1, 2]
        try await store.add(vectors: vectors, keys: keys)

        // Exact match for Key 1
        let query: [Float] = [1.0, 0.0, 0.0, 0.0]
        let results = try await store.search(vector: query, count: 1)

        #expect(results.count == 1)
        #expect(results.first?.key == 1)
        // Cosine distance of identical vectors is 0
        #expect(results.first!.distance < 0.0001)
    }
}
