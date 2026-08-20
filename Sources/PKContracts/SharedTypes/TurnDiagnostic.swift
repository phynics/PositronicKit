import Foundation

/// A dependency whose loss can change the meaning of a generated turn.
public enum TurnDependency: String, Codable, Sendable, Equatable {
    case context
    case agent
    case origin
    case workspace
}

/// Controls whether a failed turn dependency is fatal or observable degradation.
public enum TurnDegradationPolicy: String, Codable, Sendable, Equatable {
    /// Fail when a dependency explicitly requested by the turn cannot be prepared.
    case failRequired
    /// Continue with the remaining features and include every downgraded failure in metadata.
    case continueWithWarnings
}

/// Structured, host-visible metadata for a dependency that was unavailable during preparation.
public struct TurnDiagnostic: Codable, Sendable, Equatable {
    public let dependency: TurnDependency
    public let operation: String
    public let entityID: String
    public let errorIdentity: TurnEvent.ErrorIdentity?
    public let message: String

    public init(
        dependency: TurnDependency,
        operation: String,
        entityID: String,
        errorIdentity: TurnEvent.ErrorIdentity?,
        message: String
    ) {
        self.dependency = dependency
        self.operation = operation
        self.entityID = entityID
        self.errorIdentity = errorIdentity
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case dependency, operation
        case entityID = "entityId"
        case errorIdentity, message
    }
}
