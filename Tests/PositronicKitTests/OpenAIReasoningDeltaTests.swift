import Foundation
import OpenAI
import PKShared
import Testing
@testable import PKOpenAIProvider

@Suite struct OpenAIReasoningDeltaTests {
    /// Streams a chat completion chunk carrying `delta.reasoning_content` (Deepseek-style) and
    /// asserts the OpenAI provider conversion surfaces it on the transport-neutral
    /// `LLMStreamDelta.thinking` field (STAB-7).
    @Test("ChatStreamResult reasoning_content delta maps to LLMStreamDelta.thinking")
    func reasoningContentDeltaMapsToThinking() throws {
        let json = #"""
        {
          "id": "chatcmpl-1",
          "object": "chat.completion.chunk",
          "created": 1710000000,
          "model": "deepseek-reasoner",
          "choices": [
            {
              "index": 0,
              "delta": {
                "role": "assistant",
                "reasoning_content": "Let me reason about this."
              },
              "finish_reason": null
            }
          ]
        }
        """#

        let result = try JSONDecoder().decode(ChatStreamResult.self, from: Data(json.utf8))
        let chunk = result.toLLMStreamChunk()

        #expect(chunk.choices.first?.delta.thinking == "Let me reason about this.")
        #expect(chunk.choices.first?.delta.content == nil)
    }

    /// Streams a chat completion chunk carrying `delta.reasoning` (Gemini/OpenRouter-style via
    /// the OpenAI SDK) and asserts it maps to `LLMStreamDelta.thinking`.
    @Test("ChatStreamResult reasoning delta maps to LLMStreamDelta.thinking")
    func reasoningDeltaMapsToThinking() throws {
        let json = #"""
        {
          "id": "chatcmpl-2",
          "object": "chat.completion.chunk",
          "created": 1710000001,
          "model": "o1-mini",
          "choices": [
            {
              "index": 0,
              "delta": {
                "role": "assistant",
                "reasoning": "Step one."
              },
              "finish_reason": null
            }
          ]
        }
        """#

        let result = try JSONDecoder().decode(ChatStreamResult.self, from: Data(json.utf8))
        let chunk = result.toLLMStreamChunk()

        #expect(chunk.choices.first?.delta.thinking == "Step one.")
    }

    /// A non-reasoning model's chunk omits the reasoning fields entirely; the converted
    /// `LLMStreamDelta.thinking` must be `nil` so existing flows stay byte-identical.
    @Test("ChatStreamResult without reasoning fields yields nil thinking")
    func nonReasoningChunkHasNilThinking() throws {
        let json = #"""
        {
          "id": "chatcmpl-3",
          "object": "chat.completion.chunk",
          "created": 1710000002,
          "model": "gpt-4o",
          "choices": [
            {
              "index": 0,
              "delta": {
                "role": "assistant",
                "content": "Hello there."
              },
              "finish_reason": null
            }
          ]
        }
        """#

        let result = try JSONDecoder().decode(ChatStreamResult.self, from: Data(json.utf8))
        let chunk = result.toLLMStreamChunk()

        #expect(chunk.choices.first?.delta.thinking == nil)
        #expect(chunk.choices.first?.delta.content == "Hello there.")
    }
}
