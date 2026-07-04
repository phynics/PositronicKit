import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif
@testable import PKOllamaProvider
@testable import PKOpenAIProvider
@testable import PKOpenRouterProvider
import PKShared
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
}

private actor TestProviderTransport: ProviderHTTPTransport {
    enum Response {
        case lines([String], HTTPURLResponse)
    }

    private(set) var requests: [URLRequest] = []
    let responder: @Sendable (URLRequest) -> Response

    init(responder: @escaping @Sendable (URLRequest) -> Response) {
        self.responder = responder
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        switch responder(request) {
        case let .lines(lines, response):
            return (Data(lines.joined(separator: "\n").utf8), response)
        }
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        requests.append(request)
        switch responder(request) {
        case let .lines(lines, response):
            return (
                AsyncThrowingStream { continuation in
                    for line in lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                },
                response
            )
        }
    }
}

#if canImport(Network)
private struct LocalResponse: Sendable {
    var statusCode: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
}

private final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "StreamDecodingConformanceTests.LocalHTTPServer")
    private let response: LocalResponse

    static func start(response: LocalResponse) async throws -> LocalHTTPServer {
        let server = try LocalHTTPServer(response: response)
        try await server.waitUntilReady()
        return server
    }

    private init(response: LocalResponse) throws {
        self.response = response
        self.listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: 0)!)
    }

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, self.port != 0 else {
                        continuation.resume(throwing: NSError(domain: "StreamDecodingConformanceTests", code: 1))
                        return
                    }
                    continuation.resume(returning: ())
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            if let requestString = String(data: accumulated, encoding: .utf8), requestString.contains("\r\n\r\n") {
                self.sendResponse(on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func sendResponse(on connection: NWConnection) {
        let responseData = Self.makeHTTPResponseData(response)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func makeHTTPResponseData(_ response: LocalResponse) -> Data {
        let statusLine = "HTTP/1.1 \(response.statusCode) OK\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        let headerLines = headers.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
        return Data((statusLine + headerLines + "\r\n").utf8) + response.body
    }
}
#endif

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

    @Test("OpenAI streamed tool_calls survive real transport decode")
    func openAIStreamDecodesToolCallFixture() async throws {
        #if canImport(Network)
        let server = try await LocalHTTPServer.start(response: .init(
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
        #else
        Issue.record("Network framework is unavailable on this platform")
        #endif
    }

    @Test("OpenAI plain-text streaming stays unchanged")
    func openAIPlainTextStreamPreservesContent() async throws {
        #if canImport(Network)
        let server = try await LocalHTTPServer.start(response: .init(
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
        #else
        Issue.record("Network framework is unavailable on this platform")
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
}
