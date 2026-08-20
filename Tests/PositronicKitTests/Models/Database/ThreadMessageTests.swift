import Testing
@testable import PositronicKit
@testable import PKContracts
import PKUtilities
import Foundation

@Suite final class ThreadMessageTests {
    private func assertCodable<T: Codable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(value)
        _ = try decoder.decode(T.self, from: data)
    }

    @Test

    func testThreadMessageCodable() throws {
        // Need to provide a realistic `Session` ID for foreign key in DB context
        let threadID = UUID()
        let msg = ThreadMessage(
            id: UUID(),
            threadID: threadID,
            role: .user,
            content: "Ping",
            timestamp: Date()
        )
        try assertCodable(msg)
    }

    @Test

    func testToMessageConversion() throws {
        let uuid = UUID()
        let date = Date()
        let dbMsg = ThreadMessage(
            id: uuid,
            threadID: UUID(),
            role: .assistant,
            content: "Pong",
            timestamp: date
        )

        let msg = dbMsg.toMessage()
        #expect(msg.id == uuid)
        #expect(msg.role == Message.MessageRole.assistant)
        #expect(msg.content == "Pong")
        #expect(msg.timestamp == date)
    }
}
