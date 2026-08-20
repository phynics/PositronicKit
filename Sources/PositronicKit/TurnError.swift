import PKContracts

/// Errors produced while validating a facade turn request.
public enum TurnError: PKError, Sendable, Equatable {
    /// The request specified fewer than one permitted model round.
    case invalidMaxModelRounds(Int)

    public var errorDomain: String {
        PKErrorDomain.chat
    }

    public var errorCode: Int {
        switch self {
        case .invalidMaxModelRounds: 9008
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .invalidMaxModelRounds(value):
            "maxModelRounds must be at least 1; received \(value)."
        }
    }

    public var remediation: String? {
        "Pass a maxModelRounds value greater than or equal to 1."
    }
}
