import Foundation
@testable import PKUtilities
import Testing

@Suite("Prompt cache routing key")
struct PromptCacheRoutingKeyTests {
    @Test("routing key matches the golden SHA-256 derivation")
    func goldenValue() {
        // hex(SHA-256("pk.timeline." + uuid.uuidString)).prefix(32)
        let timelineID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        #expect(promptCacheRoutingKey(timelineID: timelineID) == "cc43fc6e7b6aaa5bfed4715c60e8dd7f")
    }

    @Test("routing keys differ per Timeline")
    func differsPerTimeline() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let second = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        #expect(promptCacheRoutingKey(timelineID: first) != promptCacheRoutingKey(timelineID: second))
    }

    @Test("routing key never contains the raw Timeline id and is deterministic")
    func neverRawAndDeterministic() {
        let timelineID = UUID()
        let key = promptCacheRoutingKey(timelineID: timelineID)
        #expect(!key.localizedCaseInsensitiveContains(timelineID.uuidString))
        #expect(key.count == 32)
        #expect(key == promptCacheRoutingKey(timelineID: timelineID))
    }
}
