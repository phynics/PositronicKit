import ErrorKit
import PKShared

/// Validation errors for sidecar directive composition.
public enum SidecarError: Error, Sendable, Equatable {
    case duplicateDirectiveNames([String])
    case reservedOrInvalidName(String)
    case conflictsWithExplicitStructuredOutput
}

extension SidecarError: PKError {
    public var errorDomain: String {
        PKErrorDomain.chat
    }

    public var errorCode: Int {
        switch self {
        case .duplicateDirectiveNames: return 5101
        case .reservedOrInvalidName: return 5102
        case .conflictsWithExplicitStructuredOutput: return 5103
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .duplicateDirectiveNames(names):
            return "Sidecar directive names must be unique; duplicates: \(names.joined(separator: ", "))."
        case let .reservedOrInvalidName(name):
            return "Sidecar directive name '\(name)' is empty or reserved."
        case .conflictsWithExplicitStructuredOutput:
            return "A turn cannot use both sidecar directives and an explicit structuredOutput request."
        }
    }
}
