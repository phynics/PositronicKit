import Testing
@testable import MonadCore
@testable import MonadShared
import Foundation

@Suite final class MemoryModelTests {
    private func assertCodable<T: Codable & Equatable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        #expect(value == decoded)
    }

    @Test

    func testMemoryCodable() throws {
        let memory = Memory(
            title: "User Preferences",
            content: "The user's favorite language is Swift",
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 1000),
            tags: ["swift", "preference", "user-profile"],
            metadata: ["context": "Discussing programming languages"],
            embedding: [0.1, 0.2, 0.3]
        )
        try assertCodable(memory)
        #expect(memory.tagArray.count == 3)
        #expect(memory.embedding == "[0.1,0.2,0.3]")
    }

    @Test

    func testMemoryUpdate() {
        var memory = Memory(
            title: "Test",
            content: "Test",
            embedding: []
        )
        let oldDate = memory.updatedAt

        // simulate time passing
        usleep(1000)

        memory.content = "New Content"
        // In the model, `updatedAt` is a mutable field but updating `content` doesn't automatically touch it
        // A consumer updates it manually. For the test, we'll just verify the initial creation time.
        #expect(oldDate == memory.updatedAt)
    }
}
