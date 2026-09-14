import PKTestSupport
import PositronicKit
import Testing

@Suite("TimelineRuntimeRepository conformance", .tags(.integration))
struct TimelineRuntimeRepositoryTests {
    @Test("InMemoryTimelineRuntimeRepository")
    func inMemoryRepository() async throws {
        try await TimelineRuntimeRepositoryConformanceSuite.run(staleAfter: 1) {
            InMemoryTimelineRuntimeRepository(staleAfter: 1)
        }
    }

    @Test("MockPersistenceService")
    func compositeMockRepository() async throws {
        try await TimelineRuntimeRepositoryConformanceSuite.run(staleAfter: 300) {
            MockPersistenceService()
        }
    }
}
