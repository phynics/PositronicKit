import Foundation
@testable import PKShared
import Testing

final class SharedAPIModelsTests {
    @Test
    func chatEventCodable() throws {
        let event = ChatEvent.generation("Pong")
        let data = try JSONEncoder().encode(event)
        #expect(data.count > 0)
    }

    @Test("ToolCall preserves a non-UUID provider id across a persistence round-trip (YAK-26)")
    func toolCallPreservesProviderIdAcrossCodableRoundTrip() throws {
        // Provider ids are arbitrary strings, not UUIDs. Persisting and reloading must keep the
        // exact id so the assistant tool_call still pairs with its tool-result on the next turn.
        let original = ToolCall(id: "call_KrQJZjYow2lgD6yTbqKeqAnT", name: "ls", arguments: ["path": AnyCodable(".")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: data)
        #expect(decoded.id == "call_KrQJZjYow2lgD6yTbqKeqAnT")

        // Decoding twice yields the same id (no random regeneration on reload).
        let decodedAgain = try JSONDecoder().decode(ToolCall.self, from: data)
        #expect(decodedAgain.id == decoded.id)
    }

    @Test
    func requestOriginIdentityCodable() throws {
        let origin = RequestOriginIdentity(hostname: "macbook", displayName: "Atakan's Mac", platform: "macos")
        let data = try JSONEncoder().encode(origin)
        #expect(data.count > 0)
        #expect(origin.shellWorkspaceURI.host == "macbook")
    }
}
