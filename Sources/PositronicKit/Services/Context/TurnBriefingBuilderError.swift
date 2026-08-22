import ErrorKit
import Foundation
import PKContracts
import PKUtilities

/// Error types specific to TurnBriefingBuilder
enum TurnBriefingBuilderError: PKError {
    /// Database retrieval failed
    case persistenceFailed(Error)

    var errorDomain: String { PKErrorDomain.context }

    var errorCode: Int {
        switch self {
        case .persistenceFailed: return 2002
        }
    }

    var userFriendlyMessage: String {
        switch self {
        case .persistenceFailed:
            return "Could not retrieve saved memories or notes."
        }
    }
}
