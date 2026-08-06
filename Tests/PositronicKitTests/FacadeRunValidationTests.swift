import Foundation
import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Facade run validation")
struct FacadeRunValidationTests {
    @Test("maxTurns zero fails before resolver, persistence, or provider work")
    func maxTurnsZeroFailsBeforeIO() async throws {
        try await assertInvalidMaxTurns(0)
    }

    @Test("negative maxTurns fails before resolver, persistence, or provider work")
    func negativeMaxTurnsFailsBeforeIO() async throws {
        try await assertInvalidMaxTurns(-3)
    }

    private func assertInvalidMaxTurns(_ maxTurns: Int) async throws {
        let languageModel = MockLLMService()
        let messageStore = FailingMessageStore()
        let timelineStore = FailingTimelinePersistence(fetchFails: true)
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .init(
                messageStore: messageStore,
                timelinePersistence: timelineStore,
            ),
        ))

        await #expect(throws: ChatRunError.invalidMaxTurns(maxTurns)) {
            _ = try await kit.run(ChatRunRequest(
                timelineID: UUID(),
                message: "must not reach I/O",
                maxTurns: maxTurns,
            ))
        }

        #expect(timelineStore.fetchAttemptCount == 0)
        #expect(messageStore.attemptedMessages.isEmpty)
        #expect(languageModel.chatRequestHistory.isEmpty)
        #expect(languageModel.chatCaptureHistory.isEmpty)
        #expect(languageModel.sendMessageCaptureHistory.isEmpty)
    }
}
