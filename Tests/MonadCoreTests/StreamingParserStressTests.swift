import Foundation
import Testing

@testable import MonadCore
@testable import MonadShared
@Suite struct StreamingParserStressTests {

    // MARK: - Code Block Protection

    @Test("Think tag inside code block should be treated as text")
    func testThinkTagInsideCodeBlock() {
        var parser = StreamingParser()
        // Input: ```\n<think>\n```
        // Expected: All content, no thinking.

        parser.process("```\n")
        parser.process("<think>\n")
        parser.process("```")

        let thinking: String? = parser.thinking.isEmpty ? nil : parser.thinking
        let content = parser.content

        #expect(thinking == nil)
        #expect(content.contains("<think>") == true)
    }

    @Test("Closing think tag inside code block (nested in thinking) should be preserved")
    func testClosingThinkTagInsideCodeBlockInThinking() {
        var parser = StreamingParser()
        // Input: <think>\nHere is code:\n```\nprint(\"</think>")\n```\n</think>
        // Expected: Thinking contains the code block with the tag literal.

        let chunks = [
            "<think>\n",
            "Here is code:\n",
            "```\n",
            "print(\\\"<\\/think>\\\")\\n",
            "```\\n",
            "</think>"
        ]

        for chunk in chunks {
            parser.process(chunk)
        }

        let thinking: String? = parser.thinking.isEmpty ? nil : parser.thinking
        let content = parser.content

        #expect(thinking != nil)
        #expect(thinking?.contains("print(\\\"<\\/think>\\\")") == true)
        #expect(content.isEmpty == true)
    }

    // MARK: - Partial Delimiters

    @Test("Partial code block delimiters across chunks")
    func testPartialBackticks() {
        var parser = StreamingParser()
        // Sequence: "Start", "`", "`", "`", "Code", "`", "`", "`", "End"
        // Should detect block.

        parser.process("Start ")
        parser.process("`")
        parser.process("`")
        parser.process("`")
        parser.process("Code")
        parser.process("`")
        parser.process("`")
        parser.process("`")
        parser.process(" End")

        // "```" are stripped or preserved?
        // In `extractNextSegment`, it returns "```" as text.
        // So they should be in the output.
        // But the *state* `insideCodeBlock` should have toggled correctly to protect content if it had tags.
        // Let's test with a tag inside.

        parser = StreamingParser()
        parser.process("`")
        parser.process("`")
        parser.process("`")
        parser.process("<think>")  // Should be ignored as tag
        parser.process("`")
        parser.process("`")
        parser.process("`")

        let thinking: String? = parser.thinking.isEmpty ? nil : parser.thinking
        let content2 = parser.content
        #expect(thinking == nil)
        #expect(content2.contains("<think>"))
    }

    @Test("Partial tag delimiters across chunks")
    func testPartialTags() {
        var parser = StreamingParser()
        // < t h i n k >

        let input = "<think>Inner</think>"
        for char in input {
            parser.process(String(char))
        }

        let thinking: String? = parser.thinking.isEmpty ? nil : parser.thinking
        let content = parser.content
        #expect(thinking == "Inner")
        #expect(content.isEmpty == true)
    }

    // MARK: - Edge Cases

    @Test("Orphaned closing tag triggers reclassification")
    func testOrphanedClosingTag() {
        var parser = StreamingParser()

        parser.process("Some content that ")
        parser.process("was actually thinking </think>")
        parser.process(" Real content")

        let thinking: String? = parser.thinking.isEmpty ? nil : parser.thinking
        let content = parser.content

        // The parser logic: if </think> found without <think>, it treats everything before as thinking.
        #expect(thinking?.contains("Some content that was actually thinking") == true)
        #expect(content.contains("Real content") == true)
    }

    @Test("Empty buffer handling")
    func testEmptyProcessing() {
        var parser = StreamingParser()
        parser.process("")
        let thinking: String? = parser.thinking.isEmpty ? nil : parser.thinking
        let content = parser.content
        #expect(thinking == nil)
        #expect(content == "")
    }

    @Test("Interleaved partials")
    func testInterleavedPartials() {
        var parser = StreamingParser()
        // `<` then `think>`
        parser.process("<")
        // Verify intermediate state didn't crash or output garbage
        parser.process("think>Content")

        let thinking: String? = parser.thinking.isEmpty ? nil : parser.thinking
        #expect(thinking == "Content")
    }

    // MARK: - Stress Test

    @Test("Complex interleaved stream")
    func testComplexStream() {
        var parser = StreamingParser()
        let chunks = [
            "Start ",
            "<thi", "nk>",
            "Reasoning...\n",
            "Here is a code block in thinking:\n",
            "```swift\n",
            "if x < 10 { print('hi') }\n",
            "```\n",
            "End of reasoning.",
            "</", "think>",
            "\nFinal Answer."
        ]

        for chunk in chunks {
            parser.process(chunk)
        }

        let thinking: String? = parser.thinking.isEmpty ? nil : parser.thinking
        let content = parser.content

        #expect(thinking?.contains("Reasoning...") == true)
        #expect(thinking?.contains("if x < 10") == true)
        #expect(content.contains("Final Answer") == true)
        #expect(content.contains("Start") == true)  // "Start " was before <think>
    }
}
