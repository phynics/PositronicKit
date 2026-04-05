import Foundation

/// Internal health status for core services.
public enum HealthStatus: String, Sendable, Codable {
    // swiftlint:disable:next identifier_name
    case ok
    case degraded
    case down
}
