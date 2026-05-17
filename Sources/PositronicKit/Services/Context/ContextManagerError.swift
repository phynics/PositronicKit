import ErrorKit
import Foundation
import PKShared

/// Error types specific to ContextManager
enum ContextManagerError: PKError {
    /// Embedding generation failed
    case embeddingFailed(Error)
    /// Database retrieval failed
    case persistenceFailed(Error)

    var errorDomain: String { PKErrorDomain.context }

    var errorCode: Int {
        switch self {
        case .embeddingFailed: return 2001
        case .persistenceFailed: return 2002
        }
    }

    var userFriendlyMessage: String {
        switch self {
        case .embeddingFailed:
            return "Failed to analyze your request for relevant context."
        case .persistenceFailed:
            return "Could not retrieve saved memories or notes."
        }
    }
}
