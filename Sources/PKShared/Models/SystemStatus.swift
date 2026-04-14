import Foundation

/// Represents the status of a specific system component for API responses.
public struct ComponentStatus: Codable, Sendable {
    public let status: HealthStatus
    public let details: [String: String]?

    public init(status: HealthStatus, details: [String: String]? = nil) {
        self.status = status
        self.details = details
    }
}

/// The response model for the system status endpoint.
public struct StatusResponse: Codable, Sendable {
    public let status: HealthStatus
    public let version: String
    public let uptime: TimeInterval
    public let components: [String: ComponentStatus]

    public init(
        status: HealthStatus,
        version: String,
        uptime: TimeInterval,
        components: [String: ComponentStatus]
    ) {
        self.status = status
        self.version = version
        self.uptime = uptime
        self.components = components
    }
}
