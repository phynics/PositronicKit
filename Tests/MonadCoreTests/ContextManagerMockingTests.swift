import Dependencies
import Foundation
@testable import MonadCore
@testable import MonadShared
import MonadTestSupport
import Testing

@Suite("Context Manager Mocking Tests")
struct ContextManagerMockingTests {
    @Test("Context Manager Initialization with Mocks")
    func contextManagerInitializationWithMocks() async throws {
        let mockPersistence = MockPersistenceService()
        let mockEmbedding = MockEmbeddingService()

        let contextManager = try await TestDependencies()
            .withMocks(persistence: mockPersistence, embedding: mockEmbedding)
            .run {
                ContextManager(workspace: nil)
            }

        // Just verifying initialization completes successfully
        _ = contextManager
    }
}
