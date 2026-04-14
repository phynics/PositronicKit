import Testing
import Foundation
@testable import PositronicKit
@testable import PKShared
@testable import PKPrompt

@Suite("Context Builder Truncation Tests")
struct ContextBuilderTruncationTests {

    @Test("Chat History Truncation")
    func testChatHistoryTruncation() async {
        let messages = (1...10).map { i in
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

    @Test("Context Notes Truncation")
    func testContextNotesTruncation() async {
        let longNote = String(repeating: "A long note content. ", count: 50)
        let file = ContextFile(name: "test", content: longNote, source: "test")
        let section = ContextNotes([file])

        let fullRender = await section.render()
        #expect(fullRender != nil)

        let constrainedRender = await section.render(constrainedTo: 10)
        #expect(constrainedRender != nil)

        let constrainedCount = constrainedRender?.count ?? 0
        let fullCount = fullRender?.count ?? 0

        #expect(constrainedRender?.contains("[Truncated]") == true)
        #expect(constrainedCount < fullCount)
    }

    @Test("Token Budget Application")
    func testTokenBudgetApplication() async {
        let system = SystemInstructions("System instructions")
        let messages = (1...20).map { Message.fixture(content: "msg \($0)") }
        let history = ChatHistory(messages)

        let sections: [any ContextSection] = [system, history]
        let budget = TokenBudget(maxTokens: 30, reserveForResponse: 0)
        let processed = await budget.apply(to: sections)

        #expect(processed.count == 2)

        let processedSystem = processed.first(where: { $0.id == "system" })
        #expect(processedSystem != nil)

        let processedHistory = processed.first(where: { $0.id == "chat_history" })
        #expect(processedHistory != nil)
        #expect(processedHistory?.estimatedTokens ?? 0 < history.estimatedTokens)
    }
}
