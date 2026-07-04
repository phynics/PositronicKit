import Foundation
import PKShared
import PositronicKit

/// Shared platform backend actor wrapping `MiniLMEmbedder`, consumed by `PKLocalEmbeddings`
/// on both Linux (`os(Linux)`) and Apple platforms (behind the `MiniLMEmbeddings` trait).
/// Lives here — in `PKFastEmbed`, which both conditional configurations already depend on —
/// as the single source of truth: those two configurations never compile together, so a
/// previous split into two per-platform target copies of this file could drift silently
/// without either build catching it.
public actor PKMiniLMPlatformBackend: Sendable {
    private let model: MiniLMEmbedder
    public let inputBudget: EmbeddingInputBudget

    public init(
        modelDirectory: URL,
        inputBudget: EmbeddingInputBudget = .default
    ) throws {
        do {
            model = try MiniLMEmbedder(modelDirectory: modelDirectory, inputBudget: inputBudget)
            self.inputBudget = inputBudget
        } catch let error as PKFastEmbedError {
            throw Self.mapError(error)
        }
    }

    public func generateEmbedding(for text: String) async throws -> [Float] {
        do {
            return try model.embed(text)
        } catch let error as PKFastEmbedError {
            throw Self.mapError(error)
        }
    }

    public func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        do {
            return try model.embed(texts)
        } catch let error as PKFastEmbedError {
            throw Self.mapError(error)
        }
    }

    private static func mapError(_ error: PKFastEmbedError) -> EmbeddingError {
        switch error {
        case .modelLoadFailed:
            return .nativeInitializationFailed
        case let .budgetExceeded(validationError):
            return Self.mapValidationError(validationError)
        case .invalidArgument, .bufferTooSmall, .inferenceFailed, .invalidUTF8, .nativeFailure:
            return .generationFailed
        case .abiMismatch:
            return .nativeInitializationFailed
        }
    }

    private static func mapValidationError(_ error: EmbeddingInputBudget.ValidationError) -> EmbeddingError {
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
