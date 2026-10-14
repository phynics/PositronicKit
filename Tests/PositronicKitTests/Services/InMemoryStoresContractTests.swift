import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// Implementation-specific checks for the in-memory persistence stores.
@Suite("In-memory stores", .tags(.unit))
struct InMemoryStoresContractTests {
    // MARK: - InMemoryMessageStore

    @Suite("InMemoryMessageStore", .tags(.unit))
    struct MessageStoreTests {
        @Test("saveMessage and fetchMessages round-trip per timeline")
        func saveAndFetchPerTimeline() async throws {
            let store = InMemoryMessageStore()
            let timelineA = UUID(), timelineB = UUID()

            try await store.saveMessage(TimelineMessage(timelineID: timelineA, role: .user, content: "A1"))
            try await store.saveMessage(TimelineMessage(timelineID: timelineA, role: .assistant, content: "A2"))
            try await store.saveMessage(TimelineMessage(timelineID: timelineB, role: .user, content: "B1"))

            let aMessages = try await store.fetchMessages(for: timelineA)
            let bMessages = try await store.fetchMessages(for: timelineB)
            #expect(aMessages.count == 2)
            #expect(bMessages.count == 1)
        }
    }

}
