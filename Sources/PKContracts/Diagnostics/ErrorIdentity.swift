import Foundation

/// The stable, bounded identity of a `PKError` and its blocked classification.
public struct ErrorIdentity: Sendable, Equatable, Hashable, Codable {
    /// The error domain identifying the module the error came from.
    public let domain: String

    /// The stable code for the error within its domain.
    public let code: Int

    /// Whether the error represents a blocked or approval-gated operation.
    public let isBlocked: Bool

    public init(domain: String, code: Int, isBlocked: Bool = false) {
        self.domain = domain
        self.code = code
        self.isBlocked = isBlocked
    }

    /// Extracts the first `PKError` identity in the causal chain.
    public static func extracting(from error: Error) -> ErrorIdentity? {
        if let causal = error as? CausalError {
            for cause in causal.underlyingCauses {
                if let identity = extracting(from: cause) {
                    return identity
                }
            }
            if causal.usesOwnIdentityAsFallback, let pk = error as? any PKError {
                return ErrorIdentity(domain: pk.errorDomain, code: pk.errorCode, isBlocked: pk.isBlocked)
            }
            return nil
        }
        if let pk = error as? any PKError {
            return ErrorIdentity(domain: pk.errorDomain, code: pk.errorCode, isBlocked: pk.isBlocked)
        }
        return nil
    }

    public static func == (lhs: ErrorIdentity, rhs: ErrorIdentity) -> Bool {
        lhs.domain == rhs.domain && lhs.code == rhs.code
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(domain)
        hasher.combine(code)
    }

    private enum CodingKeys: String, CodingKey {
        case domain, code, isBlocked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decode(String.self, forKey: .domain)
        code = try container.decode(Int.self, forKey: .code)
        isBlocked = try container.decodeIfPresent(Bool.self, forKey: .isBlocked) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encode(code, forKey: .code)
        try container.encode(isBlocked, forKey: .isBlocked)
    }
}
