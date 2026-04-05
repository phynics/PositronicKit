import Testing
import Foundation
@testable import MonadCore
@testable import MonadShared
@testable import MonadPrompt

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
        #expect(constrainedUnchanged is ChatHistory)
        if let h = constrainedUnchanged as? ChatHistory {
            #expect(h.messages.count == 10)
        }

        let limit = totalTokens / 2
        let constrained = history.constrained(to: limit)

        #expect(constrained is ChatHistory)
        if let h = constrained as? ChatHistory {
            #expect(h.messages.count < 10)
            #expect(h.messages.count > 0)
            #expect(h.messages.last?.content == "Message 10 content")
        }
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

        let sections: [ContextSection] = [system, history]
        let budget = TokenBudget(maxTokens: 30, reserveForResponse: 0)
        let processed = await budget.apply(to: sections)

        #expect(processed.count == 2)

        let processedSystem = processed.first(where: { $0.id == "system" })
        #expect(processedSystem != nil)
        #expect(processedSystem is SystemInstructions)

        let processedHistory = processed.first(where: { $0.id == "chat_history" })
        #expect(processedHistory != nil)

        if let h = processedHistory as? ChatHistory {
             #expect(h.messages.count < 20)
             #expect(h.messages.count > 0)
        } else {
            Issue.record("History should preserve ChatHistory type")
        }
    }
}
