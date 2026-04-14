import ErrorKit
import PKShared
import Foundation

public enum WorkspaceToolError: PKError {
    case missingDefinition

    public var errorDomain: String { PKErrorDomain.workspace }

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
