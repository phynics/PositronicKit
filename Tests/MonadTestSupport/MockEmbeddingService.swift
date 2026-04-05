import MonadShared
import MonadCore
import Foundation

public final class MockEmbeddingService: EmbeddingServiceProtocol, @unchecked Sendable {
    public var mockEmbedding: [Float] = [0.1, 0.2, 0.3]
    public var lastInput: String?
    public var useDistinctEmbeddings: Bool = false

    public init() {}

    public func generateEmbedding(for text: String) async throws -> [Float] {
        lastInput = text
        if useDistinctEmbeddings {
            let hash = abs(text.hashValue)
            var vector: [Float] = []
            for idx in 1...16 {
                vector.append(Float((hash / (idx * idx)) % 100) / 100.0)
            }
            // Normalize manually if VectorMath is Double-only or unavailable
            let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            return vector.map { $0 / magnitude }
        }
        return mockEmbedding
    }

    public func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        if useDistinctEmbeddings {
            return try await withThrowingTaskGroup(of: [Float].self) { group in
                for text in texts {
                    group.addTask { try await self.generateEmbedding(for: text) }
                }
                var results: [[Float]] = []
                for try await res in group {
                    results.append(res)
                }
                return results
            }
        }
        return texts.map { _ in mockEmbedding }
    }
}
