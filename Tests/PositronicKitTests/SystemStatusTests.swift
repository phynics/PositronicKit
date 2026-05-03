import Testing
import Foundation
@testable import PositronicKit
@testable import PKShared
@Suite("System Status Tests")
struct SystemStatusTests {
    @Test("HealthCheckable Protocol")
    func testHealthCheckableProtocol() async throws {
        struct MockService: HealthCheckable {
            func getHealthStatus() async -> HealthStatus { .ok }
            func getHealthDetails() async -> [String: String]? { ["test": "true"] }
            func checkHealth() async -> HealthStatus { .ok }
        }

        let service = MockService()
        let status = await service.checkHealth()
        let currentStatus = await service.getHealthStatus()
        let currentDetails = await service.getHealthDetails()
        #expect(status == .ok)
        #expect(currentStatus == .ok)
        #expect(currentDetails?["test"] == "true")
    }
}
