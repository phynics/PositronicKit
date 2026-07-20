import Foundation
@testable import PKPrompt
@testable import PKShared
import PKUtilities
import Testing

/// Coverage for `EmptyPrompt` — the no-op prompt primitive.
@Suite("EmptyPrompt")
struct EmptyPromptTests {

    @Test("makePromptNode returns nil")
    func makePromptNodeReturnsNil() {
        let prompt = EmptyPrompt()
        #expect(prompt.makePromptNode() == nil)
    }

    @Test("body returns self")
    func bodyReturnsSelf() {
        let prompt = EmptyPrompt()
        // The body of EmptyPrompt is EmptyPrompt itself.
        let body = prompt.body
        #expect(body is EmptyPrompt)
    }
}

/// Coverage for `PromptSection.Content` accessors and Codable.
@Suite("PromptSection.Content")
struct PromptSectionContentTests {

    @Test("text content returns the string via .text accessor")
    func textAccessor() {
        let content = PromptSection.Content.text("hello")
        #expect(content.text == "hello")
        #expect(content.messages == nil)
    }

    @Test("messages content returns the array via .messages accessor")
    func messagesAccessor() {
        let msgs = [Message(content: "hi", role: .user)]
        let content = PromptSection.Content.messages(msgs)
        #expect(content.messages?.count == 1)
        #expect(content.text == nil)
    }

    @Test("text and messages accessors return nil for the wrong case")
    func wrongCaseAccessors() {
        let textContent = PromptSection.Content.text("x")
        #expect(textContent.messages == nil)

        let msgContent = PromptSection.Content.messages([])
        #expect(msgContent.text == nil)
    }

    @Test("Content is Codable for text")
    func codableText() throws {
        let content = PromptSection.Content.text("hello world")
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(PromptSection.Content.self, from: data)
        #expect(decoded == content)
    }

    @Test("Content is Codable for messages")
    func codableMessages() throws {
        let msgs = [Message(content: "hi", role: .user)]
        let content = PromptSection.Content.messages(msgs)
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(PromptSection.Content.self, from: data)
        #expect(decoded == content)
    }

    @Test("Content equality")
    func equality() {
        #expect(PromptSection.Content.text("a") == .text("a"))
        #expect(PromptSection.Content.text("a") != .text("b"))
        #expect(PromptSection.Content.messages([]) == .messages([]))
    }
}
