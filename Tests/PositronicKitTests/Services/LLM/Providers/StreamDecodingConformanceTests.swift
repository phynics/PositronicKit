import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif
@testable import PKAnthropicProvider
@testable import PKFoundationModelsProvider
@testable import PKOllamaProvider
@testable import PKOpenAIProvider
@testable import PKOpenRouterProvider
import PKContracts
import PKTestSupport
import PKUtilities
import PositronicKit
import Synchronization
import Testing

private enum StreamWireFixtures {
    static let toolCallJSON = #"""
    {
      "id": "chunk-1",
      "model": "fixture-model",
      "choices": [
        {
          "index": 0,
          "delta": {
            "role": "assistant",
            "tool_calls": [
              {
                "index": 0,
                "id": "call_1",
                "function": {
                  "name": "lookup_weather",
                  "arguments": "{\"city\":\"Berlin\"}"
                }
              }
            ]
          },
          "finish_reason": "tool_calls"
        }
      ],
      "usage": {
        "prompt_tokens": 12,
        "completion_tokens": 5,
        "total_tokens": 17,
        "prompt_tokens_details": {
          "cached_tokens": 3
        }
      }
    }
    """#

    static let plainTextJSON = #"""
    {
      "id": "chunk-2",
      "model": "fixture-model",
      "choices": [
        {
          "index": 0,
          "delta": {
            "role": "assistant",
            "content": "hello world"
          },
          "finish_reason": "stop"
        }
      ]
    }
    """#

    static let openRouterToolCallLine = "data: \(toolCallJSON)"
    static let openRouterPlainTextLine = "data: \(plainTextJSON)"

    static let openAIToolCallChunk = """
data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1710000000,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"lookup_weather","arguments":"{\\"city\\":\\"Berlin\\"}"}}]},"finish_reason":"tool_calls"}]}

data: [DONE]
"""

    static let openAIPlainTextChunk = """
data: {"id":"chatcmpl-2","object":"chat.completion.chunk","created":1710000001,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"hello world"},"finish_reason":"stop"}]}

data: [DONE]
"""

    static let ollamaToolCallLine = #"""
    {"model":"llama3.1","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"lookup_weather","arguments":{"city":"Berlin"}}}]},"done":true,"prompt_eval_count":12,"eval_count":5}
    """#

    static let ollamaPlainTextLine = #"""
    {"model":"llama3.1","message":{"role":"assistant","content":"hello world"},"done":true,"prompt_eval_count":4,"eval_count":2}
    """#

    static let anthropicPlainTextLines = [
        #"data: {"type":"message_start","message":{"id":"msg-1","model":"claude-sonnet-4-5","usage":{"input_tokens":4}}}"#,
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#,
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello "}}"#,
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}"#,
        #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}"#,
        #"data: {"type":"message_stop"}"#,
    ]
}

private typealias TestProviderTransport = ScriptedProviderHTTPTransport

private actor ConformanceFoundationModelsSession: FoundationModelsSessionProtocol {
    private let events: [FoundationModelsSessionEvent]

    init(events: [FoundationModelsSessionEvent]) {
        self.events = events
    }

    nonisolated func streamTurn(prompt _: String) -> AsyncThrowingStream<FoundationModelsSessionEvent, Error> {
        let events = self.events
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

@Suite("Stream decoding conformance")
struct StreamDecodingConformanceTests {
    @Test("LLMStreamChunk decodes snake_case tool-call fields directly")
    func sharedChunkDecodesSnakeCaseToolCallFields() throws {
        let chunk = try JSONDecoder().decode(LLMStreamChunk.self, from: Data(StreamWireFixtures.toolCallJSON.utf8))

        let choice = try #require(chunk.choices.first)
        let toolCall = try #require(choice.delta.toolCalls?.first)

        #expect(choice.finishReason == "tool_calls")
        #expect(toolCall.id == "call_1")
        #expect(toolCall.function?.name == "lookup_weather")
        #expect(toolCall.function?.arguments == #"{"city":"Berlin"}"#)
        #expect(chunk.usage?.promptTokens == 12)
        #expect(chunk.usage?.promptTokensDetails?.cachedTokens == 3)
    }

    @Test("OpenRouter streamed tool_calls survive real transport decode")
    func openRouterStreamDecodesToolCallFixture() async throws {
        let transport = TestProviderTransport { _ in
            .lines(
                [
                    StreamWireFixtures.openRouterToolCallLine,
                    "data: [DONE]",
                ],
                HTTPURLResponse(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            )
        }

        let client = OpenRouterClient(apiKey: "secret", transport: transport)
        let chunks = try await client.chatStream(
            messages: [LLMMessage(role: .user, content: "list files")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        let toolCallChunk = try #require(chunks.first { $0.choices.first?.delta.toolCalls?.isEmpty == false })
        let toolCall = try #require(toolCallChunk.choices.first?.delta.toolCalls?.first)

        #expect(toolCall.id == "call_1")
        #expect(toolCall.function?.name == "lookup_weather")
        #expect(toolCall.function?.arguments == #"{"city":"Berlin"}"#)
        #expect(toolCallChunk.choices.first?.finishReason == "tool_calls")
    }

    @Test("OpenRouter plain-text streaming stays unchanged")
    func openRouterPlainTextStreamPreservesContent() async throws {
        let transport = TestProviderTransport { _ in
            .lines(
                [
                    StreamWireFixtures.openRouterPlainTextLine,
                    "data: [DONE]",
                ],
                HTTPURLResponse(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            )
        }

        let client = OpenRouterClient(apiKey: "secret", transport: transport)
        let chunks = try await client.chatStream(
            messages: [LLMMessage(role: .user, content: "say hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        #expect(chunks.first?.choices.first?.delta.content == "hello world")
        #expect(chunks.first?.choices.first?.delta.toolCalls == nil)
    }

    @Test(
        "OpenAI streamed tool_calls survive real transport decode",
        .disabled(if: !networkFrameworkAvailable, "Network framework is unavailable on this platform")
    )
    func openAIStreamDecodesToolCallFixture() async throws {
        #if canImport(Network)
        let server = try await TestHTTPServer.start(response: .init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data(StreamWireFixtures.openAIToolCallChunk.utf8)
        ))
        defer { server.stop() }

        let client = OpenAIClient(
            apiKey: "secret",
            host: "127.0.0.1",
            port: Int(server.port),
            scheme: "http",
            session: .shared,
            middlewares: []
        )

        let chunks = try await client.chatStream(
            messages: [LLMMessage(role: .user, content: "lookup weather")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        let toolCallChunk = try #require(chunks.first { $0.choices.first?.delta.toolCalls?.isEmpty == false })
        let toolCall = try #require(toolCallChunk.choices.first?.delta.toolCalls?.first)

        #expect(toolCall.id == "call_1")
        #expect(toolCall.function?.name == "lookup_weather")
        #expect(toolCall.function?.arguments == #"{"city":"Berlin"}"#)
        #expect(toolCallChunk.choices.first?.finishReason == "tool_calls")
        #endif
    }

    @Test(
        "OpenAI plain-text streaming stays unchanged",
        .disabled(if: !networkFrameworkAvailable, "Network framework is unavailable on this platform")
    )
    func openAIPlainTextStreamPreservesContent() async throws {
        #if canImport(Network)
        let server = try await TestHTTPServer.start(response: .init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data(StreamWireFixtures.openAIPlainTextChunk.utf8)
        ))
        defer { server.stop() }

        let client = OpenAIClient(
            apiKey: "secret",
            host: "127.0.0.1",
            port: Int(server.port),
            scheme: "http",
            session: .shared,
            middlewares: []
        )

        let chunks = try await client.chatStream(
            messages: [LLMMessage(role: .user, content: "say hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        #expect(chunks.first?.choices.first?.delta.content == "hello world")
        #expect(chunks.first?.choices.first?.delta.toolCalls == nil)
        #endif
    }

    @Test("Ollama streamed tool_calls survive real transport decode")
    func ollamaStreamDecodesToolCallFixture() async throws {
        let transport = TestProviderTransport { _ in
            .lines(
                [StreamWireFixtures.ollamaToolCallLine],
                HTTPURLResponse(url: URL(string: "http://localhost:11434/api/chat")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/x-ndjson"])!
            )
        }

        let client = OllamaClient(endpoint: "http://localhost:11434", modelName: "llama3.1", transport: transport)
        let chunks = try await client.chatStream(
            messages: [LLMMessage(role: .user, content: "lookup weather")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        let toolCallChunk = try #require(chunks.first { $0.choices.first?.delta.toolCalls?.isEmpty == false })
        let toolCall = try #require(toolCallChunk.choices.first?.delta.toolCalls?.first)

        #expect(toolCall.id?.isEmpty == false)
        #expect(toolCall.function?.name == "lookup_weather")
        #expect(toolCall.function?.arguments == #"{"city":"Berlin"}"#)
        #expect(toolCallChunk.choices.first?.finishReason == "tool_calls")
    }

    @Test("Ollama plain-text streaming stays unchanged")
    func ollamaPlainTextStreamPreservesContent() async throws {
        let transport = TestProviderTransport { _ in
            .lines(
                [StreamWireFixtures.ollamaPlainTextLine],
                HTTPURLResponse(url: URL(string: "http://localhost:11434/api/chat")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/x-ndjson"])!
            )
        }

        let client = OllamaClient(endpoint: "http://localhost:11434", modelName: "llama3.1", transport: transport)
        let chunks = try await client.chatStream(
            messages: [LLMMessage(role: .user, content: "say hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        #expect(chunks.first?.choices.first?.delta.content == "hello world")
        #expect(chunks.first?.choices.first?.delta.toolCalls == nil)
    }

    @Test("Anthropic plain-text events normalize through the shared stream contract")
    func anthropicPlainTextStreamPreservesContent() async throws {
        let transport = TestProviderTransport(responses: [
            .lines(
                StreamWireFixtures.anthropicPlainTextLines,
                HTTPURLResponse(
                    url: URL(string: "https://api.anthropic.com/v1/messages")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
            ),
        ])
        let client = AnthropicClient(apiKey: "secret", maxRetries: 0, transport: transport)
        let chunks = try await client.chatStream(
            messages: [LLMMessage(role: .user, content: "say hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        #expect(chunks.compactMap { $0.choices.first?.delta.content }.joined() == "hello world")
        #expect(chunks.last?.choices.first?.finishReason == "stop")
    }

    @Test("Foundation Models session events normalize through the shared stream contract")
    func foundationModelsPlainTextStreamPreservesContent() async throws {
        let client = FoundationModelsClient(
            makeSession: { _, _ in
                ConformanceFoundationModelsSession(events: [
                    .textDelta("hello "),
                    .textDelta("world"),
                    .finished(.stop),
                ])
            }
        )
        let chunks = try await client.chatStream(
            messages: [LLMMessage(role: .user, content: "say hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        #expect(chunks.compactMap { $0.choices.first?.delta.content }.joined() == "hello world")
        #expect(chunks.last?.choices.first?.finishReason == "stop")
    }
}

private let networkFrameworkAvailable: Bool = {
    #if canImport(Network)
    true
    #else
    false
    #endif
}()
