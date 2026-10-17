import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Prompt Builder Truncation Tests", .tags(.unit))
struct PromptBuilderTruncationTests {
    @Test("Chat History Truncation")
    func chatHistoryTruncation() {
        let messages = (1 ... 10).map { i in
            Message.fixture(content: "Message \(i) content")
        }

        let history = ChatHistory(messages)
        let totalTokens = history.estimatedTokens

        let constrainedUnchanged = history.constrained(to: totalTokens + 100)
        #expect(constrainedUnchanged.messages.count == 10)

        let limit = totalTokens / 2
        let constrained = history.constrained(to: limit)
        #expect(constrained.messages.count < 10)
        #expect(constrained.messages.count > 0)
        #expect(constrained.messages.last?.content == "Message 10 content")
    }
}
