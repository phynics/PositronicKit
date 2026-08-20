import Foundation
import PKTestSupport
import PositronicKit
import Testing

@Suite("BatchFailingMessageStore concurrency")
struct BatchFailingMessageStoreTests {
    private enum SaveOutcome: Sendable {
        case success
        case typedFailure
        case unexpectedFailure(String)
    }

    @Test("concurrent saves admit exactly the configured threshold")
    func concurrentSavesAdmitExactlyConfiguredThreshold() async throws {
        let store = BatchFailingMessageStore()
        store.failAfterSaveCount = 25
        let threadID = fixedUUID(1)
        let messages = (0 ..< 100).map { index in
            ThreadMessage(
                id: fixedUUID(index + 100),
                threadID: threadID,
                role: .user,
                content: "message-\(index)"
            )
        }

        let outcomes = await withTaskGroup(of: SaveOutcome.self, returning: [SaveOutcome].self) { group in
            for message in messages {
                group.addTask {
                    do {
                        try await store.saveMessage(message)
                        return .success
                    } catch let error as FailingStoreError {
                        if case .saveFailed = error {
                            return .typedFailure
                        }
                        return .unexpectedFailure(String(describing: error))
                    } catch {
                        return .unexpectedFailure(String(describing: error))
                    }
                }
            }

            var outcomes: [SaveOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }

        let successes = outcomes.filter { if case .success = $0 { true } else { false } }.count
        let typedFailures = outcomes.filter { if case .typedFailure = $0 { true } else { false } }.count
        let unexpectedFailures = outcomes.compactMap { outcome -> String? in
            if case let .unexpectedFailure(message) = outcome { message } else { nil }
        }

        #expect(successes == 25)
        #expect(typedFailures == 75)
        #expect(unexpectedFailures.isEmpty)
        #expect(store.saveCallCount == 100)
        #expect(store.messages.count == 25)
    }

    private func fixedUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
