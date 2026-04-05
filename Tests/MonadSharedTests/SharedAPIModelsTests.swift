import Foundation
@testable import MonadCore
@testable import MonadShared
import Testing

@Suite final class SharedAPIModelsTests {
    // MARK: - Test Helpers

    private func assertCodable<T: Codable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(value)
        _ = try decoder.decode(T.self, from: data)
    }

    // MARK: - SystemStatus Tests

    @Test

    func componentStatusCodable() throws {
        let comp = ComponentStatus(status: .ok, details: ["db": "ok"])
        try assertCodable(comp)
    }

    // MARK: - ChatAPI Tests

    @Test

    func chatAPIModels() throws {
        let req = ChatRequest(message: "Ping", toolOutputs: nil, clientId: UUID())
        // ChatRequest only conforms to Codable, skip Equatable assertion for now
        let data = try JSONEncoder().encode(req)
        #expect(data.count > 0)

        let event = ChatEvent.generation("Pong")
        let eData = try JSONEncoder().encode(event)
        #expect(eData.count > 0)
    }

    // MARK: - WorkspaceAPI Tests

    @Test

    func workspaceAPIModels() throws {
        let attachReq = AttachWorkspaceRequest(workspaceId: UUID())
        // AttachWorkspaceRequest only conforms to Codable
        let data = try JSONEncoder().encode(attachReq)
        #expect(data.count > 0)
    }

    // MARK: - ToolAPI Tests

    @Test

    func toolInfoCodable() throws {
        let info = ToolInfo(id: "tool-1", name: "test_tool", description: "Does tests")
        // ToolInfo only conforms to Codable and Identifiable, not Equatable
        let data = try JSONEncoder().encode(info)
        #expect(data.count > 0)
    }

    // MARK: - ClientModels Tests

    @Test

    func clientIdentityCodable() throws {
        let client = ClientIdentity(hostname: "macbook", displayName: "Atakan's Mac", platform: "macos")
        let data = try JSONEncoder().encode(client)
        #expect(data.count > 0)

        #expect(client.shellWorkspaceURI.host == "macbook")
    }
}
