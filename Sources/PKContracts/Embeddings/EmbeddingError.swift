import Foundation
import ErrorKit

public enum EmbeddingError: PKError, Equatable {
    case modelUnavailable
    case generationFailed
    case modelDirectoryMissing
    case modelFilesMissing
    case modelChecksumMismatch
    case nativeInitializationFailed
    case batchTextCountLimitExceeded(max: Int, actual: Int)
    case perTextByteLimitExceeded(max: Int, actual: Int)
    case totalBatchByteLimitExceeded(max: Int, actual: Int)

    public var errorDomain: String { PKErrorDomain.embedding }

    public var errorCode: Int {
        switch self {
        case .modelUnavailable: return 8001
        case .generationFailed: return 8002
        case .modelDirectoryMissing: return 8003
        case .modelFilesMissing: return 8004
        case .modelChecksumMismatch: return 8005
        case .nativeInitializationFailed: return 8006
        case .batchTextCountLimitExceeded: return 8007
        case .perTextByteLimitExceeded: return 8008
        case .totalBatchByteLimitExceeded: return 8009
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .modelUnavailable:
            return "Local embedding capabilities are not available on this device."
        case .generationFailed:
            return "Failed to process the text for embedding. Please try again."
        case .modelDirectoryMissing:
            return "The local MiniLM model directory could not be found."
        case .modelFilesMissing:
            return "The local MiniLM model directory is missing required files."
        case .modelChecksumMismatch:
            return "The local MiniLM model files do not match the expected checksum."
        case .nativeInitializationFailed:
            return "The local MiniLM backend could not be initialized."
        case let .batchTextCountLimitExceeded(max, actual):
            return "Embedding input exceeded the batch text-count limit of \(max) item(s) (\(actual) provided)."
        case let .perTextByteLimitExceeded(max, actual):
            return "Embedding input exceeded the per-text byte limit of \(max) bytes (\(actual) bytes provided)."
        case let .totalBatchByteLimitExceeded(max, actual):
            return "Embedding input exceeded the total batch byte limit of \(max) bytes (\(actual) bytes provided)."
        }
    }
}
