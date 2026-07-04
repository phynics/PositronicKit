import PKShared
@testable import PositronicKit
import Testing

struct ToolOutputParserTests {
    @Test("Pipe-delimited tool calls recover from a truncated/trailing-comma argument blob")
    func pipeDelimitedRecoversFromMalformedArguments() {
        let content = "<|tool_call_begin|>functions.search:0<|tool_call_argument_begin|>" +
            #"{"query": "swift concurrency",}<|tool_call_end|>"#
        let calls = ToolOutputParser.parse(from: content)

        #expect(calls.count == 1)
        #expect(calls.first?.name == "search")
        #expect(calls.first?.arguments["query"]?.value as? String == "swift concurrency")
    }

    @Test("XML-wrapped tool calls recover from a truncated/trailing-comma payload")
    func xmlToolCallRecoversFromMalformedPayload() {
        let content = """
        <tool_call>{"name": "lookup", "arguments": {"id": "42",}}</tool_call>
        """
        let calls = ToolOutputParser.parse(from: content)

        #expect(calls.count == 1)
        #expect(calls.first?.name == "lookup")
        #expect(calls.first?.arguments["id"]?.value as? String == "42")
    }
}
