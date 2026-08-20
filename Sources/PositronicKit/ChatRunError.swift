import PKContracts

/// Errors produced while validating a facade chat-run request.
public enum ChatRunError: PKError, Sendable, Equatable {
    /// The request specified fewer than one permitted model turn.
    case invalidMaxTurns(Int)

    public var errorDomain: String {
        PKErrorDomain.chat
    }

    public var errorCode: Int {
        switch self {
        case .invalidMaxTurns: 9008
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .invalidMaxTurns(value):
            "maxTurns must be at least 1; received \(value)."
        }
    }

    public var remediation: String? {
        "Pass a maxTurns value greater than or equal to 1."
    }
}
