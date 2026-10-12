import PKTestSupport
import PositronicKit
import Testing

@Suite("AgentStoreProtocol conformance", .tags(.integration))
struct AgentStoreContractTests {
    @Test("InMemoryAgentStore")
    func inMemoryStore() async throws {
        try await AgentStoreConformanceSuite.run {
            InMemoryAgentStore()
        }
    }

    @Test("MockPersistenceService")
    func compositeMockStore() async throws {
        try await AgentStoreConformanceSuite.run {
            MockPersistenceService()
        }
    }
}
