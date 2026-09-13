import PKTestSupport
import PositronicKit
import Testing

@Suite("AgentStoreProtocol conformance", .tags(.integration))
struct AgentStoreContractTests {
    @Test("InMemoryAgentStore")
    func inMemoryStore() async throws {
        try await AgentStoreConformanceSuite.run { timelines in
            InMemoryAgentStore(timelines: timelines)
        }
    }

    @Test("MockPersistenceService")
    func compositeMockStore() async throws {
        try await AgentStoreConformanceSuite.run { timelines in
            let store = MockPersistenceService()
            store.timelines = timelines
            return store
        }
    }
}
