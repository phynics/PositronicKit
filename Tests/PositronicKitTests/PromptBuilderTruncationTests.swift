import Foundation
@testable import PKPrompt
@testable import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

@Suite("Prompt Builder Truncation Tests")
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

    @Test("Token Budget Application")
    func tokenBudgetApplication() async {
        let system = SystemInstructions("System instructions")
        let messages = (1 ... 20).map { Message.fixture(content: "msg \($0)") }
        let history = ChatHistory(messages)

        let sections: [any Prompt] = [system, history]
        let budget = TokenBudget(maxTokens: 30, reserveForResponse: 0)
        let processed = try! await budget.result(forPrompts: sections).sections

        #expect(processed.count == 2)

        let processedSystem = processed.first(where: { $0.id == "system" })
        #expect(processedSystem != nil)

        let processedHistory = processed.first(where: { $0.id == "chat_history" })
        #expect(processedHistory != nil)
        #expect(processedHistory?.estimatedTokens ?? 0 < history.estimatedTokens)
    }
}
