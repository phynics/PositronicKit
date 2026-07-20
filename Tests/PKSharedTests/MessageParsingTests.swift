import Foundation
@testable import PKShared
import Testing

/// Coverage for `Message.parseResponse(_:)` and `Message.displayContent` — the
/// reasoning-tag and tool-call-tag extraction helpers.
///
/// These parse think-tag reasoning blocks and strip tool-call tags from display content.
/// They were previously untested directly.
@Suite("Message parsing")
struct MessageParsingTests {

    // MARK: - parseResponse

    @Test("Extracts reasoning from think tags and returns clean content")
    func extractsReasoning() {
        let raw = "<think>Let me break this down step by step.</think>\nThe answer is 42."
        let (content, reasoning) = Message.parseResponse(raw)

        #expect(content == "The answer is 42.")
        #expect(reasoning == "Let me break this down step by step.")
    }

    @Test("Returns nil reasoning when no think tags present")
    func noThinkTagsReturnsNilReasoning() {
        let raw = "Just a plain response."
        let (content, reasoning) = Message.parseResponse(raw)

        #expect(content == "Just a plain response.")
        #expect(reasoning == nil)
    }

    @Test("Handles multiline reasoning blocks")
    func multilineReasoning() {
        let raw = "<think>Step 1: Analyze\nStep 2: Conclude</think>\nFinal answer."
        let (content, reasoning) = Message.parseResponse(raw)

        #expect(content == "Final answer.")
        #expect(reasoning?.contains("Step 1") == true)
        #expect(reasoning?.contains("Step 2") == true)
    }

    @Test("Returns content unchanged when think tags are empty")
    func emptyThinkTags() {
        let raw = "<think></think>Just the answer."
        let (content, reasoning) = Message.parseResponse(raw)

        #expect(content == "Just the answer.")
        #expect(reasoning == "")
    }

    @Test("Handles multiple think blocks, keeping only the first reasoning")
    func multipleThinkBlocks() {
        let raw = "<think>First reasoning</think>\nMiddle\n<think>Second reasoning</think>\nEnd."
        let (content, reasoning) = Message.parseResponse(raw)

        #expect(reasoning == "First reasoning")
        #expect(content.contains("Middle") == true)
        #expect(content.contains("End.") == true)
    }

    // MARK: - displayContent

    @Test("displayContent strips tool_call tags from content")
    func stripsToolCallTags() {
        let raw = "Before <tool_call>{\"name\":\"ls\"}</tool_call> After"
        let message = Message(content: raw, role: .user)
        let displayed = message.displayContent

        #expect(!displayed.contains("<tool_call>"))
        #expect(!displayed.contains("</tool_call>"))
        #expect(displayed.contains("Before"))
        #expect(displayed.contains("After"))
    }

    @Test("displayContent strips tool_call tags wrapped in code blocks")
    func stripsToolCallInCodeBlocks() {
        let raw = "Start\n```xml\n<tool_call>{\"name\":\"ls\"}</tool_call>\n```\nEnd"
        let message = Message(content: raw, role: .user)
        let displayed = message.displayContent

        #expect(!displayed.contains("<tool_call>"))
        #expect(!displayed.contains("```"))
    }

    @Test("displayContent returns content unchanged when no tool_call tags present")
    func noToolCallTagsUnchanged() {
        let message = Message(content: "Just plain text.", role: .user)
        #expect(message.displayContent == "Just plain text.")
    }

    @Test("displayContent handles multiline tool_call blocks")
    func multilineToolCall() {
        let raw = "Start\n<tool_call>\n{\"name\":\"ls\",\"arguments\":{\"path\":\"/\"}}\n</tool_call>\nEnd"
        let message = Message(content: raw, role: .user)
        let displayed = message.displayContent

        #expect(!displayed.contains("<tool_call>"))
        #expect(displayed.contains("Start"))
        #expect(displayed.contains("End"))
    }

    @Test("displayContent is case-insensitive for tool_call tags")
    func caseInsensitiveToolCall() {
        let raw = "Before <TOOL_CALL>{}</TOOL_CALL> After"
        let message = Message(content: raw, role: .user)
        let displayed = message.displayContent

        #expect(!displayed.contains("<TOOL_CALL>"))
        #expect(displayed.contains("Before"))
        #expect(displayed.contains("After"))
    }
}
