import Testing
@testable import MonadShared
import Foundation

@Suite final class ChatEventTests {
    @Test

    func testGenerationCancelledEvent() throws {
        // This should fail to compile after the rename or if I use the new name now
        // But for TDD, I should write something that expects 'generationCancelled'
        let event = ChatEvent.generationCancelled()

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ChatEvent.self, from: data)

        if case let .error(errorEvent) = decoded {
            if case .generationCancelled = errorEvent {
                // Success
            } else {
                Issue.record("Expected .generationCancelled, got \(errorEvent)")
            }
        } else {
            Issue.record("Expected .error, got \(decoded)")
        }
    }
}
