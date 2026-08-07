import Foundation
import PKShared
import PKUtilities
import PositronicKit
import Synchronization

/// In-memory `EmbeddingServiceProtocol` test double.
///
/// Configurable: `mockEmbedding` (the fixed vector returned by default), `useDistinctEmbeddings`
/// (when `true`, derives a distinct normalized vector per input text via a hash instead of
/// returning `mockEmbedding` for everything — useful for similarity-search tests that need
/// differentiated vectors), and `inputBudget` (mirrors `LocalEmbeddingService`'s validation
/// so budget-rejection paths can be exercised).
/// Call-capture: `lastInput` (the most recently admitted single-text embedding request).
/// Each operation snapshots its result configuration once; concurrent batch generation does not
/// recursively mutate `lastInput` from child tasks.
public final class MockEmbeddingService: EmbeddingServiceProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var mockEmbedding: [Float] = [0.1, 0.2, 0.3]
        var lastInput: String?
        var useDistinctEmbeddings = false
    }

    private let state = Mutex(State())

    public var mockEmbedding: [Float] {
        get { state.withLock { $0.mockEmbedding } }
        set { state.withLock { $0.mockEmbedding = newValue } }
    }

    public var lastInput: String? {
        get { state.withLock { $0.lastInput } }
        set { state.withLock { $0.lastInput = newValue } }
    }

    public var useDistinctEmbeddings: Bool {
        get { state.withLock { $0.useDistinctEmbeddings } }
        set { state.withLock { $0.useDistinctEmbeddings = newValue } }
    }

    /// Budget used to validate inputs before returning mock vectors, mirroring
    /// `LocalEmbeddingService`. Defaults to `.default` so existing tests are
    /// unaffected; inject a tighter budget to exercise rejection paths (PKR-8).
    public let inputBudget: EmbeddingInputBudget

    public init(inputBudget: EmbeddingInputBudget = .default) {
        self.inputBudget = inputBudget
    }

    public func generateEmbedding(for text: String) async throws -> [Float] {
        try validate(text)
        let snapshot = state.withLock { state in
            state.lastInput = text
            return (embedding: state.mockEmbedding, useDistinct: state.useDistinctEmbeddings)
        }
        return snapshot.useDistinct ? distinctEmbedding(for: text) : snapshot.embedding
    }

    public func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        try validate(texts)
        let snapshot = state.withLock {
            (embedding: $0.mockEmbedding, useDistinct: $0.useDistinctEmbeddings)
        }
        if snapshot.useDistinct {
            return texts.map { distinctEmbedding(for: $0) }
        }
        return texts.map { _ in snapshot.embedding }
    }

    private func distinctEmbedding(for text: String) -> [Float] {
        let hash = abs(text.hashValue)
        var vector: [Float] = []
        for idx in 1 ... 16 {
            vector.append(Float((hash / (idx * idx)) % 100) / 100.0)
        }
        // Normalize manually if VectorMath is Double-only or unavailable
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return vector.map { $0 / magnitude }
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
