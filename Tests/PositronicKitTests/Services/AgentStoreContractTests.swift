import PKTestSupport
import PositronicKit
import Testing

@Suite("AgentStoreProtocol conformance")
struct AgentStoreContractTests {
    @Test("InMemoryAgentStore")
    func inMemoryStore() async throws {
        try await AgentStoreConformanceSuite.run { threads in
            InMemoryAgentStore(threads: threads)
        }
    }

    @Test("MockPersistenceService")
    func compositeMockStore() async throws {
        try await AgentStoreConformanceSuite.run { threads in
            let store = MockPersistenceService()
            store.threads = threads
            return store
        }
    }
}
