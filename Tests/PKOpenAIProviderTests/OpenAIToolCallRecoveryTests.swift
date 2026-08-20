import Foundation
import OpenAI
@testable import PKOpenAIProvider
import PKContracts
import PKUtilities
import Testing

@Suite struct OpenAIToolCallRecoveryTests {
    @Test("ChatResult tool_calls payload can be converted into a recovery stream chunk")
    func chatResultToolCallsRecoverToChunk() throws {
        let json = #"""
        {
          "id": "chatcmpl-123",
          "object": "chat.completion",
          "created": 1710000000,
          "model": "gpt-4o",
          "choices": [
            {
              "index": 0,
              "finish_reason": "tool_calls",
              "message": {
                "role": "assistant",
                "content": null,
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

        let result = try JSONDecoder().decode(ChatResult.self, from: Data(json.utf8))
        let chunk = try #require(result.toLLMToolCallRecoveryChunk())

        #expect(chunk.choices.first?.finishReason == "tool_calls")
        let toolCalls = try #require(chunk.choices.first?.delta.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.id == "call_1")
        #expect(toolCalls.first?.function?.name == "lookup_weather")
        #expect(toolCalls.first?.function?.arguments == #"{"city":"Berlin"}"#)
        #expect(chunk.usage?.totalTokens == 15)
    }

    @Test("Recovery chunk is not produced when finish reason is not tool_calls")
    func noRecoveryChunkWithoutToolCallFinishReason() throws {
        let json = #"""
        {
          "id": "chatcmpl-456",
          "object": "chat.completion",
          "created": 1710000001,
          "model": "gpt-4o",
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

        let result = try JSONDecoder().decode(ChatResult.self, from: Data(json.utf8))
        #expect(result.toLLMToolCallRecoveryChunk() == nil)
    }
}
