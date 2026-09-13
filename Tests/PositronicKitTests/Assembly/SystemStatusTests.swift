import Foundation
@testable import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

@Suite("System Status Tests")
struct SystemStatusTests {
    @Test("HealthCheckable Protocol")
    func healthCheckableProtocol() async {
        struct MockService: HealthCheckable {
            var healthDetails: [String: String]? {
                get async { ["test": "true"] }
            }

            func checkHealth() async -> HealthStatus {
                .ok
            }
        }

        let service = MockService()
        let status = await service.checkHealth()
        let currentDetails = await service.healthDetails
        #expect(status == .ok)
        #expect(currentDetails?["test"] == "true")
    }
}
