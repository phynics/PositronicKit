import Foundation
@testable import PKContracts
import Testing

final class MemoryModelTests {
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

    func memoryCodable() throws {
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

    func memoryUpdate() {
        var memory = Memory(
            title: "Test",
            content: "Test",
            embedding: []
        )
        let oldDate = memory.updatedAt

        memory.content = "New Content"
        // In the model, `updatedAt` is a mutable field but updating `content` doesn't automatically touch it
        // A consumer updates it manually. For the test, we'll just verify the initial creation time.
        #expect(oldDate == memory.updatedAt)
    }

    // MARK: - Prompt Formatting

    @Test("promptString includes ID, title, tags, and content")
    func promptStringIncludesAllFields() {
        let memory = Memory(
            title: "Swift Tips",
            content: "Use guard let for unwrapping.",
            tags: ["swift", "ios"]
        )
        let prompt = memory.promptString

        #expect(prompt.contains("ID: \(memory.id.uuidString)"))
        #expect(prompt.contains("Title: Swift Tips"))
        #expect(prompt.contains("Tags: swift, ios"))
        #expect(prompt.contains("Content:"))
        #expect(prompt.contains("Use guard let for unwrapping."))
    }

    @Test("promptString omits the Tags line when no tags are present")
    func promptStringOmitsTagsWhenEmpty() {
        let memory = Memory(title: "No Tags", content: "body")
        let prompt = memory.promptString

        #expect(!prompt.contains("Tags:"))
        #expect(prompt.contains("Title: No Tags"))
    }

    @Test("Array.promptContent returns empty string for an empty array")
    func emptyArrayPromptContentIsEmpty() {
        let memories: [Memory] = []
        #expect(memories.promptContent == "")
    }

    @Test("Array.promptContent joins multiple memories under a Memories header")
    func arrayPromptContentJoinsMemories() {
        let memories = [
            Memory(title: "First", content: "first body", tags: ["a"]),
            Memory(title: "Second", content: "second body", tags: ["b"]),
        ]
        let content = memories.promptContent

        #expect(content.hasPrefix("# Memories"))
        #expect(content.contains("Title: First"))
        #expect(content.contains("Title: Second"))
        #expect(content.contains("first body"))
        #expect(content.contains("second body"))
    }

    // MARK: - Computed accessors

    @Test("tagArray returns empty for malformed JSON")
    func tagArrayMalformedJSON() {
        let memory = Memory(
            id: UUID(), title: "T", content: "C",
            createdAt: Date(), updatedAt: Date(),
            tags: "not-json", metadata: "{}", embedding: "[]"
        )
        #expect(memory.tagArray == [])
    }

    @Test("embeddingVector returns empty for malformed JSON")
    func embeddingVectorMalformedJSON() {
        let memory = Memory(
            id: UUID(), title: "T", content: "C",
            createdAt: Date(), updatedAt: Date(),
            tags: "[]", metadata: "{}", embedding: "not-json"
        )
        #expect(memory.embeddingVector == [])
    }

    @Test("metadataDict returns empty for malformed JSON")
    func metadataDictMalformedJSON() {
        let memory = Memory(
            id: UUID(), title: "T", content: "C",
            createdAt: Date(), updatedAt: Date(),
            tags: "[]", metadata: "not-json", embedding: "[]"
        )
        #expect(memory.metadataDict == [:])
    }
}
