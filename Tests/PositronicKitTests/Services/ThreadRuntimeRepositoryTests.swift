import PKTestSupport
import PositronicKit
import Testing

@Suite("ThreadRuntimeRepository conformance")
struct ThreadRuntimeRepositoryTests {
    @Test("InMemoryThreadRuntimeRepository")
    func inMemoryRepository() async throws {
        try await ThreadRuntimeRepositoryConformanceSuite.run(staleAfter: 1) {
            InMemoryThreadRuntimeRepository(staleAfter: 1)
        }
    }

    @Test("MockPersistenceService")
    func compositeMockRepository() async throws {
        try await ThreadRuntimeRepositoryConformanceSuite.run(staleAfter: 300) {
            MockPersistenceService()
        }
    }
}
