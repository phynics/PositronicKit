import Foundation
@testable import MonadCore
@testable import MonadShared
import Testing

@Suite("Test Fixtures and Builders Tests")
struct TestFixtureTests {
    @Test("Message Builder creates valid message with defaults")
    func messageBuilder() {
        let msg = Message.fixture(content: "Custom Content")
        #expect(msg.content == "Custom Content")
        #expect(msg.role == .user) // Default
    }

    @Test("Memory Builder creates valid memory")
    func memoryBuilder() {
        let memory = Memory.fixture(title: "Important Fact")
        #expect(memory.title == "Important Fact")
        #expect(!memory.content.isEmpty)
    }
}
