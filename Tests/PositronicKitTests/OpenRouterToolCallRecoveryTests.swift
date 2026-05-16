import Foundation
@testable import PKOpenRouterProvider
import PKShared
import Testing

@Suite struct OpenRouterToolCallRecoveryTests {
    @Test("OpenRouter non-stream tool_calls payload can be converted into a recovery stream chunk")
    func openRouterToolCallsRecoverToChunk() throws {
        let client = OpenRouterClient(apiKey: "test")
        let json = #"""
        {
          "id": "or-123",
          "model": "openai/gpt-4o",
          "choices": [
            {
              "index": 0,
              "finish_reason": "tool_calls",
              "message": {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                  {
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "lookup_weather",
                      "arguments": "{\"city\":\"Berlin\"}"
                    }
                  }
                ]
              }
            }
          ],
          "usage": {
            "prompt_tokens": 10,
            "completion_tokens": 5,
            "total_tokens": 15
          }
        }
        """#

        let recovered = try client.makeToolCallRecoveryChunk(from: Data(json.utf8))
        let chunk = try #require(recovered)

        #expect(chunk.choices.first?.finishReason == "tool_calls")
        let toolCalls = try #require(chunk.choices.first?.delta.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.id == "call_1")
        #expect(toolCalls.first?.function?.name == "lookup_weather")
        #expect(toolCalls.first?.function?.arguments == #"{"city":"Berlin"}"#)
        #expect(chunk.usage?.totalTokens == 15)
    }

    @Test("OpenRouter recovery chunk is not produced when finish reason is not tool_calls")
    func noOpenRouterRecoveryWithoutToolCallFinishReason() throws {
        let client = OpenRouterClient(apiKey: "test")
        let json = #"""
        {
          "id": "or-456",
          "model": "openai/gpt-4o",
          "choices": [
            {
              "index": 0,
              "finish_reason": "stop",
              "message": {
                "role": "assistant",
                "content": "hello"
              }
            }
          ]
        }
        """#

        #expect(try client.makeToolCallRecoveryChunk(from: Data(json.utf8)) == nil)
    }
}
