import Foundation

/// Internal health status for core services.
public enum HealthStatus: String, Sendable, Codable {
    /// The service is fully operational.
    // swiftlint:disable:next identifier_name
    case ok
    /// The service is operational but impaired (e.g. running with reduced capability).
    case degraded
    /// The service is unavailable.
    case down
}
