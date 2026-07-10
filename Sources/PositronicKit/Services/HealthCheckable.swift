import PKShared

/// Protocol for services that can report their health status.
public protocol HealthCheckable: Sendable {
    /// Returns any additional details about the health status.
    func getHealthDetails() async -> [String: String]?

    /// Performs a fresh health check and returns the result.
    func checkHealth() async -> HealthStatus
}
