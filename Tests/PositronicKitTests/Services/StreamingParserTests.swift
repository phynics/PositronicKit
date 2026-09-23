import Foundation
@testable import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

@Suite(.tags(.unit))
final class StreamingParserTests {
    // MARK: - Thinking Tag Parsing

    @Test

    func streamingParserNormalText() {
        var parser = StreamingParser()
        parser.process("Hello")
        parser.process(" World")

        #expect(parser.content == "Hello World")
        #expect(parser.thinking == "")
        #expect(!(parser.isThinking))
    }

    @Test

    func streamingParserWithThinkingTags() {
        var parser = StreamingParser()
        parser.process("Here is my reasoning: <th")
        #expect(parser.content == "Here is my reasoning: ") // "<th" buffered
        #expect(!(parser.isThinking)) // Still resolving tag

        parser.process("ink>This is deep thought.</thi")
        #expect(parser.isThinking) // Inside thought, "</thi" buffered

        parser.process("nk>And now the answer.")

        #expect(parser.thinking == "This is deep thought.")
        #expect(parser.content == "Here is my reasoning: And now the answer.")
        #expect(!(parser.isThinking))
    }

    @Test

    func streamingParserOrphanedClosingTag() {
        var parser = StreamingParser()
        // DeepSeek and other models sometimes start sending </think> without opening it
        parser.process("Wait, let me think about this...\n</think>\nYes, the answer is 42.")

        #expect(parser.hasReclassified)
        #expect(parser.thinking == "Wait, let me think about this...\n")
        #expect(parser.content == "\nYes, the answer is 42.")
    }

    @Test

    func streamingParserLiteralReclassifyMarkerIsTreatedAsContent() {
        var parser = StreamingParser()
        // The reclassification signal must not be an in-band string: a model emitting the
        // literal marker should be passed through verbatim as content, not reinterpreted.
        parser.process("The constant RECLASSIFY_THINKING_MARKER is internal.")

        #expect(parser.content == "The constant RECLASSIFY_THINKING_MARKER is internal.")
        #expect(parser.thinking == "")
        #expect(!(parser.hasReclassified))
    }

    @Test

    func streamingParserCodeBlockAvoidance() {
        var parser = StreamingParser()
        parser.process("```xml\n<think>This should NOT be parsed as thinking</think>\n```")

        #expect(parser.thinking == "")
        #expect(parser.content.contains("<think>This should NOT be parsed"))
        #expect(!(parser.isThinking))
    }

    // MARK: - Pipe-Delimited Marker Stripping

    @Test

    func streamingParserStripsPipeDelimitedMarkers() {
        var parser = StreamingParser()

        parser.process("A: I'll help you. <|tool_calls_section_begin|> <|tool_call_begin|> functions.list_workspaces:0 <|tool_call_argument_begin|> {} <|tool_call_end|> <|tool_calls_section_end|>")

        // The pipe-delimited markers should be stripped; only visible text remains
        #expect(!(parser.content.contains("<|")))
        #expect(!(parser.content.contains("|>")))
        #expect(parser.content.contains("I'll help you"))
    }

    @Test

    func streamingParserPreservesNormalAngleBrackets() {
        var parser = StreamingParser()
        parser.process("Use <div> tags in HTML")

        // Regular angle brackets should remain
        #expect(parser.content.contains("<div>"))
    }
}
