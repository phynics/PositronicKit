import Foundation
import MonadCore
import Testing

@Suite
struct StreamingParserCodeBlockTests {
    @Test("Test tool call inside markdown code block")
    func testToolCallInCodeBlock() {
        let parser = StreamingParser()
        let input = """
        I will calculate that.
        ```xml
        <tool_call>
        {"name": "calculate", "arguments": {"expression": "2+2"}}
        </tool_call>
        ```
        Here is the result.
        """

        let (content, toolCalls) = parser.extractToolCalls(from: input)

        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].name == "calculate")

        // Verify code block fences are removed
        #expect(!content.contains("```xml"))
        #expect(!content.contains("```"))
        #expect(content.contains("I will calculate that."))
        #expect(content.contains("Here is the result."))
    }

    @Test("Test tool call inside standard code block")
    func testToolCallInStandardCodeBlock() {
        let parser = StreamingParser()
        let input = """
        Thinking...
        ```
        <tool_call>
        {"name": "search", "arguments": {"query": "test"}}
        </tool_call>
        ```
        """

        let (_, toolCalls) = parser.extractToolCalls(from: input)

        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].name == "search")
    }

    @Test("Test mixed content with code block tool call")
    func testMixedContent() {
        let parser = StreamingParser()
        let input = """
        Here is a code block:
        ```swift
        print("Hello")
        ```
        And here is a tool call:
        ```xml
        <tool_call>
        {"name": "test", "arguments": {}}
        </tool_call>
        ```
        """

        let (content, toolCalls) = parser.extractToolCalls(from: input)

        #expect(toolCalls.count == 1)
        #expect(content.contains("print(\"Hello\")")) // Should preserve regular code block
        #expect(!content.contains("<tool_call>")) // Should remove tool call
    }
}
