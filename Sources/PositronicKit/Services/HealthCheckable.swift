import PKContracts
import PKUtilities

/// Protocol for services that can report their health status.
///
/// A health check may perform provider or storage I/O. It is separate from the model
/// readiness snapshot, which must remain local and non-networking.
public protocol HealthCheckable: Sendable {
    /// Returns any additional details about the health status.
    func getHealthDetails() async -> [String: String]?

    /// Performs a fresh health check and returns the result.
    func checkHealth() async -> HealthStatus
}
