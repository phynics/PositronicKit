import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenAI
import PKShared
import PKTestSupport
import PKUtilities
import PositronicKit
import Synchronization
import Testing
@testable import PKOpenAIProvider

/// Coverage for `OpenAIClient` methods and the `PKOpenAIProvider` factory that are not
/// exercised by the transport-contract or conversion suites.
///
/// Targets:
/// - The public convenience `init(apiKey:modelName:host:port:scheme:...)` (delegates to
///   the package init).
/// - `sendMessage(_:responseFormat:generationParameters:)` — the non-streaming one-shot.
/// - The tool-call recovery path inside `chatStream` (stream finishes with
///   `finish_reason: tool_calls` but no streamed `delta.toolCalls`).
/// - `mapProviderError`'s `CancellationError` passthrough.
/// - `PKOpenAIProvider.makeClientAndRegisterStructuredOutputAdapter(configuration:)` for both `.openAI` and
///   OpenAI-compatible providers.
@Suite("OpenAI client coverage", .serialized)
struct OpenAIClientCoverageTests {

    // MARK: - Shared test infrastructure

    private func makeStreamingServer(body: String) async throws -> TestHTTPServer {
        try await TestHTTPServer.start(response: .sse(body))
    }

    private func makeJSONServer(body: String, statusCode: Int = 200) async throws -> TestHTTPServer {
        try await TestHTTPServer.start(response: .json(body, statusCode: statusCode))
    }

    // MARK: - Public convenience init

    @Test("Public convenience init delegates to the package init with URLSession.shared")
    func publicConvenienceInit() async throws {
        let server = try await makeStreamingServer(body: #"""
data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":0,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"hi"}}]}

data: [DONE]

"""#)
        defer { server.stop() }

        // Use the public init (not the package init with session/middlewares).
        let client = OpenAIClient(
            apiKey: "secret-key",
            modelName: "gpt-4o",
            host: "127.0.0.1",
            port: Int(server.port),
            scheme: "http",
            timeoutInterval: 5.0,
            maxRetries: 0
        )

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )
        var chunks: [LLMStreamChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        #expect(!chunks.isEmpty)
        #expect(chunks.first?.choices.first?.delta.content == "hi")
    }

    // MARK: - sendMessage

    @Test("sendMessage accumulates streamed content into a single string")
    func sendMessageAccumulatesContent() async throws {
        let server = try await makeStreamingServer(body: #"""
data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":0,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":"Hello"}}]}

data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":0,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":", world!"}}]}

data: [DONE]

"""#)
        defer { server.stop() }

        let client = OpenAIClient(
            apiKey: "secret-key",
            modelName: "gpt-4o",
            host: "127.0.0.1",
            port: Int(server.port),
            scheme: "http",
            timeoutInterval: 5.0,
            maxRetries: 0
        )

        let result = try await client.sendMessage("hello")
        #expect(result == "Hello, world!")
    }

    @Test("sendMessage returns empty string when no content is streamed")
    func sendMessageEmptyContent() async throws {
        let server = try await makeStreamingServer(body: #"""
data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":0,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant"}}]}

data: [DONE]

"""#)
        defer { server.stop() }

        let client = OpenAIClient(
            apiKey: "secret-key",
            modelName: "gpt-4o",
            host: "127.0.0.1",
            port: Int(server.port),
            scheme: "http",
            timeoutInterval: 5.0,
            maxRetries: 0
        )

        let result = try await client.sendMessage("hello")
        #expect(result == "")
    }

    @Test("sendMessage propagates HTTP errors as LLMServiceError")
    func sendMessagePropagatesErrors() async throws {
        let server = try await makeJSONServer(
            body: "{\"error\":{\"message\":\"rate limited\"}}",
            statusCode: 429
        )
        defer { server.stop() }

        let client = OpenAIClient(
            apiKey: "secret-key",
            modelName: "gpt-4o",
            host: "127.0.0.1",
            port: Int(server.port),
            scheme: "http",
            timeoutInterval: 5.0,
            maxRetries: 0
        )

        do {
            _ = try await client.sendMessage("hello")
            Issue.record("Expected sendMessage to throw")
        } catch let error as LLMServiceError {
            #expect(error == .httpError(provider: "OpenAI", statusCode: 429, responseBody: "", retryAfter: nil))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Tool-call recovery path

    @Test("chatStream recovers tool calls from a non-stream response when stream omits delta.toolCalls")
    func toolCallRecoveryFromNonStreamResponse() async throws {
        // The stream finishes with finish_reason: tool_calls but never sends delta.tool_calls.
        // The client should fall back to a non-streaming request and recover the tool calls.
        // We use a two-response server: first the stream, then the non-stream JSON.
        let streamBody = #"""
data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":0,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":"tool_calls"}]}

data: [DONE]

"""#
        let nonStreamBody = #"""
{"id":"chatcmpl-1","object":"chat.completion","created":0,"model":"gpt-4o","choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Berlin\"}"}}]}}]}
"""#

        let server = try await TestHTTPServer.startSequential(responses: [
            .sse(streamBody),
            .json(nonStreamBody),
        ])
        defer { server.stop() }

        let client = OpenAIClient(
            apiKey: "secret-key",
            modelName: "gpt-4o",
            host: "127.0.0.1",
            port: Int(server.port),
            scheme: "http",
            timeoutInterval: 5.0,
            maxRetries: 0
        )

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "What's the weather?")],
            tools: [LLMToolDefinition(name: "get_weather", description: "Get weather")],
            toolChoice: .auto,
            responseFormat: nil,
            generationParameters: nil
        )

        var chunks: [LLMStreamChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        // The recovery chunk should carry the tool call.
        let recoveryChunk = chunks.first { $0.choices.first?.delta.toolCalls != nil }
        let toolCalls = try #require(recoveryChunk?.choices.first?.delta.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.id == "call_1")
        #expect(toolCalls.first?.function?.name == "get_weather")
        #expect(toolCalls.first?.function?.arguments == #"{"city":"Berlin"}"#)
    }

    // MARK: - mapProviderError CancellationError passthrough

    @Test("mapProviderError passes through CancellationError unchanged")
    func cancellationErrorPassthrough() async throws {
        let client = OpenAIClient(
            apiKey: "key",
            modelName: "gpt-4o",
            host: "127.0.0.1",
            port: 12345,
            scheme: "http",
            timeoutInterval: 5.0,
            maxRetries: 0
        )
        let cancellation = CancellationError()
        let mapped = await client.mapProviderError(cancellation, provider: "OpenAI")
        #expect(mapped is CancellationError)
    }

    @Test("mapProviderError passes through unknown errors unchanged")
    func unknownErrorPassthrough() async throws {
        let client = OpenAIClient(
            apiKey: "key",
            modelName: "gpt-4o",
            host: "127.0.0.1",
            port: 12345,
            scheme: "http",
            timeoutInterval: 5.0,
            maxRetries: 0
        )
        struct CustomError: Error {}
        let mapped = await client.mapProviderError(CustomError(), provider: "OpenAI")
        #expect(mapped is CustomError)
    }

    // MARK: - PKOpenAIProvider.makeClient

    @Test("makeClient for .openAI registers native structured output adapter")
    func makeClientForOpenAI() {
        let config = LLMConfiguration.fixture(
            endpoint: "https://api.openai.com",
            modelName: "gpt-4o",
            apiKey: "sk-test",
            activeProvider: .openAI
        )
        let client = PKOpenAIProvider.makeClientAndRegisterStructuredOutputAdapter(configuration: config)
        #expect(client is OpenAIClient)
    }

    @Test("makeClient for OpenAI-compatible provider registers compatible structured output adapter")
    func makeClientForOpenAICompatible() {
        let config = LLMConfiguration.fixture(
            endpoint: "https://api.deepseek.com",
            modelName: "deepseek-chat",
            apiKey: "sk-test",
            activeProvider: .openAICompatible
        )
        let client = PKOpenAIProvider.makeClientAndRegisterStructuredOutputAdapter(configuration: config)
        #expect(client is OpenAIClient)
    }

    @Test("makeClient falls back to default host/port/scheme for invalid endpoint")
    func makeClientInvalidEndpointFallback() {
        let config = LLMConfiguration.fixture(
            endpoint: "not-a-url",
            modelName: "gpt-4o",
            apiKey: "sk-test",
            activeProvider: .openAI
        )
        // Should not crash; falls back to api.openai.com:443/https.
        let client = PKOpenAIProvider.makeClientAndRegisterStructuredOutputAdapter(configuration: config)
        #expect(client is OpenAIClient)
    }
}
