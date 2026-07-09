import Foundation
import PKShared
import PositronicKit

/// In-memory `EmbeddingServiceProtocol` test double.
///
/// Configurable: `mockEmbedding` (the fixed vector returned by default), `useDistinctEmbeddings`
/// (when `true`, derives a distinct normalized vector per input text via a hash instead of
/// returning `mockEmbedding` for everything — useful for similarity-search tests that need
/// differentiated vectors), and `inputBudget` (mirrors `LocalEmbeddingService`'s validation
/// so budget-rejection paths can be exercised).
/// Call-capture: `lastInput` (the most recent single-text embedding request).
public final class MockEmbeddingService: EmbeddingServiceProtocol, @unchecked Sendable {
    public var mockEmbedding: [Float] = [0.1, 0.2, 0.3]
    public var lastInput: String?
    public var useDistinctEmbeddings: Bool = false

    /// Budget used to validate inputs before returning mock vectors, mirroring
    /// `LocalEmbeddingService`. Defaults to `.default` so existing tests are
    /// unaffected; inject a tighter budget to exercise rejection paths (PKR-8).
    public let inputBudget: EmbeddingInputBudget

    public init(inputBudget: EmbeddingInputBudget = .default) {
        self.inputBudget = inputBudget
    }

    public func generateEmbedding(for text: String) async throws -> [Float] {
        try validate(text)
        lastInput = text
        if useDistinctEmbeddings {
            let hash = abs(text.hashValue)
            var vector: [Float] = []
            for idx in 1 ... 16 {
                vector.append(Float((hash / (idx * idx)) % 100) / 100.0)
            }
            // Normalize manually if VectorMath is Double-only or unavailable
            let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            return vector.map { $0 / magnitude }
        }
        return mockEmbedding
    }

    public func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        try validate(texts)
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

    private func validate(_ text: String) throws {
        do {
            try inputBudget.validate(text)
        } catch let error as EmbeddingInputBudget.ValidationError {
            throw mapValidationError(error)
        }
    }

    private func validate(_ texts: [String]) throws {
        do {
            try inputBudget.validate(texts)
        } catch let error as EmbeddingInputBudget.ValidationError {
            throw mapValidationError(error)
        }
    }

    private func mapValidationError(_ error: EmbeddingInputBudget.ValidationError) -> EmbeddingError {
        switch error {
        case let .batchTextCountLimitExceeded(max, actual):
            return .batchTextCountLimitExceeded(max: max, actual: actual)
        case let .perTextByteLimitExceeded(max, actual):
            return .perTextByteLimitExceeded(max: max, actual: actual)
        case let .totalBatchByteLimitExceeded(max, actual):
            return .totalBatchByteLimitExceeded(max: max, actual: actual)
        }
    }
}
