import ErrorKit
import Foundation
import PKShared

/// Error types specific to ContextManager
public enum ContextManagerError: MonadError {
    /// Embedding generation failed
    case embeddingFailed(Error)
    /// Database retrieval failed
    case persistenceFailed(Error)

    public var errorDomain: String { MonadErrorDomain.context }

    public var errorCode: Int {
        switch self {
        case .embeddingFailed: return 2001
        case .persistenceFailed: return 2002
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .embeddingFailed:
            return "Failed to analyze your request for relevant context."
        case .persistenceFailed:
            return "Could not retrieve saved memories or notes."
        }
    }
}
