import PKContracts
import PKTestSupport
import PositronicKit
import Testing

@Suite("Domain value custom reflection")
struct TestReflectionTests {
    @Test("Message reflects its identity, role, content, and status")
    func messageReflection() {
        let message = Message.fixture(role: .assistant, content: "hello")
        let mirror = Mirror(reflectingForTest: message)
        let labels = mirror.children.compactMap(\.label)
        #expect(labels == ["id", "role", "content", "status", "reasoning", "toolCalls"])
    }

    @Test("TurnEvent reflects its category")
    func turnEventReflection() {
        let mirror = Mirror(reflectingForTest: TurnEvent.generation("hi"))
        #expect(mirror.children.compactMap(\.label) == ["delta"])
    }

    @Test("TurnOutcome reflects its terminal case")
    func turnOutcomeReflection() {
        let mirror = Mirror(reflectingForTest: TurnOutcome.failed(message: "boom"))
        #expect(mirror.children.compactMap(\.label) == ["failed"])
    }
}
