import Testing
import Foundation
@testable import MonadCore
@testable import MonadShared
@Suite("System Status Tests")
struct SystemStatusTests {

    @Test("StatusResponse Serialization")
    func testStatusResponseSerialization() throws {
        let component = ComponentStatus(status: .ok, details: ["provider": "openai"])
        let response = StatusResponse(
            status: .ok,
            version: "1.0.0",
            uptime: 3600,
            components: ["ai_provider": component]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(response)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(StatusResponse.self, from: data)

        #expect(decoded.status == .ok)
        #expect(decoded.version == "1.0.0")
        #expect(decoded.uptime == 3600)
        #expect(decoded.components["ai_provider"]?.status == .ok)
        #expect(decoded.components["ai_provider"]?.details?["provider"] == "openai")
    }

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
