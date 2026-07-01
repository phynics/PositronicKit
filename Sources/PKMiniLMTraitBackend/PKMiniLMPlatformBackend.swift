#if MiniLMEmbeddings
import Foundation
import PKFastEmbed
import PKShared
import PositronicKit

public actor PKMiniLMPlatformBackend: Sendable {
    private let model: MiniLMEmbedder
    public let inputBudget: EmbeddingInputBudget

    public init(
        modelDirectory: URL,
        inputBudget: EmbeddingInputBudget = .default
    ) throws {
        do {
            self.model = try MiniLMEmbedder(modelDirectory: modelDirectory, inputBudget: inputBudget)
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
        case let .invalidArgument(message):
            if let validationError = EmbeddingInputBudget.ValidationError(message: message) {
                return Self.mapValidationError(validationError)
            }
            return .generationFailed
        case .bufferTooSmall, .inferenceFailed, .invalidUTF8, .nativeFailure:
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
#endif
