import Foundation
import ErrorKit
import PKShared

public enum EmbeddingError: PKError {
    case modelUnavailable
    case generationFailed
    case platformNotSupported

    public var errorDomain: String { PKErrorDomain.embedding }

    public var errorCode: Int {
        switch self {
        case .modelUnavailable: return 8001
        case .generationFailed: return 8002
        case .platformNotSupported: return 8003
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .modelUnavailable:
            return "Local embedding capabilities are not available on this device."
        case .generationFailed:
            return "Failed to process the text for embedding. Please try again."
        case .platformNotSupported:
            return "Local text analysis is only supported on Apple devices."
        }
    }
}
