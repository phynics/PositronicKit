import Testing
import Foundation
@testable import MonadCore
@testable import MonadShared

@Suite final class StreamingParserTests {

    // MARK: - Thinking Tag Parsing

    @Test

    func testStreamingParserNormalText() {
        var parser = StreamingParser()
        parser.process("Hello")
        parser.process(" World")

        #expect(parser.content == "Hello World")
        #expect(parser.thinking == "")
        #expect(!(parser.isThinking))
    }

    @Test

    func testStreamingParserWithThinkingTags() {
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

    func testStreamingParserOrphanedClosingTag() {
        var parser = StreamingParser()
        // DeepSeek and other models sometimes start sending </think> without opening it
        parser.process("Wait, let me think about this...\n</think>\nYes, the answer is 42.")

        #expect(parser.hasReclassified)
        #expect(parser.thinking == "Wait, let me think about this...\n")
        #expect(parser.content == "\nYes, the answer is 42.")
    }

    @Test

    func testStreamingParserCodeBlockAvoidance() {
        var parser = StreamingParser()
        parser.process("```xml\n<think>This should NOT be parsed as thinking</think>\n```")

        #expect(parser.thinking == "")
        #expect(parser.content.contains("<think>This should NOT be parsed"))
        #expect(!(parser.isThinking))
    }

    // MARK: - Tool Extraction

    @Test

    func testToolExtraction() throws {
        let parser = StreamingParser()
        let response = """
        I will use the tool now.
        ```xml
        <tool_call>
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "get_weather",
          "arguments": {
            "location": "SF"
          }
        }
        </tool_call>
        ```
        And that's it.
        """

        let (cleanText, tools) = parser.extractToolCalls(from: response)

        // Ensure XML was stripped from text
        #expect(!(cleanText.contains("<tool_call>")))
        #expect(cleanText.contains("I will use the tool now."))
        #expect(cleanText.contains("And that's it."))

        // Ensure tool was extracted
        #expect(tools.count == 1)
        #expect(tools[0].name == "get_weather")
        #expect(tools[0].arguments["location"]?.value as? String == "SF")
        #expect(tools[0].id == UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    }

    @Test

    func testMultipleToolExtractionsWithoutCodeFences() throws {
        let parser = StreamingParser()
        let response = """
        <tool_call>
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "toolA",
          "arguments": {}
        }
        </tool_call>
        <tool_call>
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "name": "toolB",
          "arguments": {}
        }
        </tool_call>
        """

        let (cleanText, tools) = parser.extractToolCalls(from: response)
        #expect(cleanText.trimmingCharacters(in: .whitespacesAndNewlines) == "")
        #expect(tools.count == 2)
        #expect(tools[0].name == "toolA")
        #expect(tools[1].name == "toolB")
    }

    // MARK: - Pipe-Delimited Marker Stripping

    @Test

    func testStreamingParserStripsPipeDelimitedMarkers() {
        var parser = StreamingParser()

        parser.process("A: I'll help you. <|tool_calls_section_begin|> <|tool_call_begin|> functions.list_workspaces:0 <|tool_call_argument_begin|> {} <|tool_call_end|> <|tool_calls_section_end|>")

        // The pipe-delimited markers should be stripped; only visible text remains
        #expect(!(parser.content.contains("<|")))
        #expect(!(parser.content.contains("|>")))
        #expect(parser.content.contains("I'll help you"))
    }

    @Test

    func testStreamingParserPreservesNormalAngleBrackets() {
        var parser = StreamingParser()
        parser.process("Use <div> tags in HTML")

        // Regular angle brackets should remain
        #expect(parser.content.contains("<div>"))
    }
}
