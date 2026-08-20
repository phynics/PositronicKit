import Foundation
import PKContracts
import PKTestSupport
import PositronicKit
import Testing

@Suite("MockMemoryStore concurrency")
struct MockMemoryStoreConcurrencyTests {
    @Test("concurrent unique memory saves preserve every ID")
    func concurrentUniqueMemorySavesPreserveEveryID() async throws {
        let store = MockMemoryStore()
        let expectedIDs = Set((0 ..< 100).map(fixedID))
        let memories = expectedIDs.map { id in
            Memory.fixture(id: id, title: id.uuidString, content: "memory-\(id.uuidString)")
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for memory in memories {
                group.addTask {
                    _ = try await store.saveMemory(memory, policy: .immediate)
                }
            }
            try await group.waitForAll()
        }

        let actualIDs = Set(try await store.fetchAllMemories().map(\.id))
        #expect(actualIDs.count == 100)
        #expect(actualIDs == expectedIDs)
    }

    private func fixedID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }
}
