import ErrorKit
import Foundation

/// Errors produced by embedding clients.
///
/// Codes `8001`, `8002`, and `8007`–`8009` keep the numbers of the former embedding subsystem.
/// Codes `8003`–`8006` remain unused; they belonged to the removed MiniLM backend. Transport
/// failures reuse the provider HTTP error types.
public enum EmbeddingError: PKError, Equatable {
    case modelUnavailable
    case generationFailed
    case batchTextCountLimitExceeded(max: Int, actual: Int)
    case perTextByteLimitExceeded(max: Int, actual: Int)
    case totalBatchByteLimitExceeded(max: Int, actual: Int)
    case incompatibleSpaces(EmbeddingSpace, EmbeddingSpace)
    case responseCountMismatch(expected: Int, actual: Int)

    public var errorDomain: String { PKErrorDomain.embedding }

    public var errorCode: Int {
        switch self {
        case .modelUnavailable: return 8001
        case .generationFailed: return 8002
        case .batchTextCountLimitExceeded: return 8007
        case .perTextByteLimitExceeded: return 8008
        case .totalBatchByteLimitExceeded: return 8009
        case .incompatibleSpaces: return 8010
        case .responseCountMismatch: return 8011
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .modelUnavailable:
            return "The embedding model is not available on this device."
        case .generationFailed:
            return "Failed to process the text for embedding. Please try again."
        case let .batchTextCountLimitExceeded(max, actual):
            return "Embedding input exceeded the batch text-count limit of \(max) item(s) (\(actual) provided)."
        case let .perTextByteLimitExceeded(max, actual):
            return "Embedding input exceeded the per-text byte limit of \(max) bytes (\(actual) bytes provided)."
        case let .totalBatchByteLimitExceeded(max, actual):
            return "Embedding input exceeded the total batch byte limit of \(max) bytes (\(actual) bytes provided)."
        case let .incompatibleSpaces(first, second):
            return "Cannot compare embeddings from different spaces: \(first.provider)/\(first.model) and \(second.provider)/\(second.model)."
        case let .responseCountMismatch(expected, actual):
            return "The embedding provider returned \(actual) embedding(s) for \(expected) input(s)."
        }
    }
}
