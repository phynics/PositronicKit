import Testing
@testable import MonadCore
@testable import MonadShared
import Foundation

@Suite final class MessageTests {

    // MARK: - Test Helpers

    // Test exact string to verify specific encoder settings
    private func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8)!
    }

    private func assertCodable<T: Codable & Equatable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        #expect(value == decoded)
    }

    // MARK: - Message Tests

    @Test

    func testMessageUserRole() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let message = Message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            timestamp: date,
            content: "Hello",
            role: .user,
            isSummary: false
        )

        try assertCodable(message)
        let jsonString = try encodeToString(message)
        #expect(jsonString.contains("\"role\":\"user\""))
        #expect(jsonString.contains("\"content\":\"Hello\""))
    }

    @Test

    func testMessageAssistantRole() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let msg = Message(
            timestamp: date,
            content: "Response",
            role: .assistant,
            isSummary: true
        )
        try assertCodable(msg)
        let jsonString = try encodeToString(msg)
        #expect(jsonString.contains("\"role\":\"assistant\""))
        #expect(jsonString.contains("\"isSummary\":true"))
    }

    @Test

    func testMessageSystemRole() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let msg = Message(
            timestamp: date,
            content: "System Prompt",
            role: .system
        )
        try assertCodable(msg)
        let jsonString = try encodeToString(msg)
        #expect(jsonString.contains("\"role\":\"system\""))
    }
}
