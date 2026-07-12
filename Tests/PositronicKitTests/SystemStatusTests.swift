import Foundation
@testable import PKShared
import PKUtilities
@testable import PositronicKit
import Testing

@Suite("System Status Tests")
struct SystemStatusTests {
    @Test("HealthCheckable Protocol")
    func healthCheckableProtocol() async {
        struct MockService: HealthCheckable {
            func getHealthDetails() async -> [String: String]? {
                ["test": "true"]
            }

            func checkHealth() async -> HealthStatus {
                .ok
            }
        }

        let service = MockService()
        let status = await service.checkHealth()
        let currentDetails = await service.getHealthDetails()
        #expect(status == .ok)
        #expect(currentDetails?["test"] == "true")
    }
}
