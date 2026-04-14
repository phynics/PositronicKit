import ErrorKit
import PKShared
import Foundation

public enum WorkspaceToolError: MonadError {
    case missingDefinition

    public var errorDomain: String { MonadErrorDomain.workspace }

    public var errorCode: Int {
        switch self {
        case .missingDefinition: return 3101
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .missingDefinition:
            return "The workspace tool's configuration is incomplete."
        }
    }
}
