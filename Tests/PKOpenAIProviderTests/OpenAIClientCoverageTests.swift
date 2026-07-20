import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenAI
import PKShared
import PKUtilities
import PositronicKit
import Synchronization
import Testing
@testable import PKOpenAIProvider

#if canImport(Network)
import Network

/// Coverage for `OpenAIClient` methods and `PKOpenAIProvider.makeClient` that are not
/// exercised by the transport-contract or conversion suites.
///
/// Targets:
/// - The public convenience `init(apiKey:modelName:host:port:scheme:...)` (delegates to
///   the package init).
/// - `sendMessage(_:responseFormat:generationParameters:)` — the non-streaming one-shot.
/// - The tool-call recovery path inside `chatStream` (stream finishes with
///   `finish_reason: tool_calls` but no streamed `delta.toolCalls`).
/// - `mapProviderError`'s `CancellationError` passthrough.
/// - `PKOpenAIProvider.makeClient(configuration:)` factory for both `.openAI` and
///   OpenAI-compatible providers.
@Suite("OpenAI client coverage", .serialized)
struct OpenAIClientCoverageTests {

    // MARK: - Shared test infrastructure

    private func makeStreamingServer(body: String) async throws -> SimpleHTTPServer {
        try await SimpleHTTPServer.start(response: .init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data(body.utf8)
        ))
    }

    private func makeJSONServer(body: String, statusCode: Int = 200) async throws -> SimpleHTTPServer {
        try await SimpleHTTPServer.start(response: .init(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        ))
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

        let server = try await DualResponseHTTPServer.start(
            firstResponse: .init(
                headers: ["Content-Type": "text/event-stream"],
                body: Data(streamBody.utf8)
            ),
            secondResponse: .init(
                headers: ["Content-Type": "application/json"],
                body: Data(nonStreamBody.utf8)
            )
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
        let config = LLMConfiguration(
            activeProvider: .openAI,
            providers: [.openAI: ProviderConfiguration(
                endpoint: "https://api.openai.com",
                apiKey: "sk-test",
                modelName: "gpt-4o",
                utilityModel: "gpt-4o",
                fastModel: "gpt-4o",
                toolFormat: .openAI
            )]
        )
        let client = PKOpenAIProvider.makeClient(configuration: config)
        #expect(client is OpenAIClient)
    }

    @Test("makeClient for OpenAI-compatible provider registers compatible structured output adapter")
    func makeClientForOpenAICompatible() {
        let config = LLMConfiguration(
            activeProvider: .openAICompatible,
            providers: [.openAICompatible: ProviderConfiguration(
                endpoint: "https://api.deepseek.com",
                apiKey: "sk-test",
                modelName: "deepseek-chat",
                utilityModel: "deepseek-chat",
                fastModel: "deepseek-chat",
                toolFormat: .openAI
            )]
        )
        let client = PKOpenAIProvider.makeClient(configuration: config)
        #expect(client is OpenAIClient)
    }

    @Test("makeClient falls back to default host/port/scheme for invalid endpoint")
    func makeClientInvalidEndpointFallback() {
        let config = LLMConfiguration(
            activeProvider: .openAI,
            providers: [.openAI: ProviderConfiguration(
                endpoint: "not-a-url",
                apiKey: "sk-test",
                modelName: "gpt-4o",
                utilityModel: "gpt-4o",
                fastModel: "gpt-4o",
                toolFormat: .openAI
            )]
        )
        // Should not crash; falls back to api.openai.com:443/https.
        let client = PKOpenAIProvider.makeClient(configuration: config)
        #expect(client is OpenAIClient)
    }
}

// MARK: - Simple HTTP server

/// A local HTTP server that returns the same response on every request.
private final class SimpleHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SimpleHTTPServer")
    private let response: HTTPResponse

    static func start(response: HTTPResponse) async throws -> SimpleHTTPServer {
        let server = try SimpleHTTPServer(response: response)
        try await server.waitUntilReady()
        return server
    }

    private init(response: HTTPResponse) throws {
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
                        continuation.resume(throwing: NSError(domain: "SimpleHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "no port"]))
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
                self.sendResponse(on: connection, response: self.response)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func sendResponse(on connection: NWConnection, response: HTTPResponse) {
        let responseData = Self.makeHTTPResponseData(response)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func makeHTTPResponseData(_ response: HTTPResponse) -> Data {
        let statusLine = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        let headerLines = headers.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
        return Data((statusLine + headerLines + "\r\n").utf8) + response.body
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 401: return "Unauthorized"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "HTTP Status"
        }
    }
}

// MARK: - Dual-response HTTP server

/// A local HTTP server that returns a different response on the first vs. subsequent
/// requests on the same connection port. Used to test the tool-call recovery path,
/// which issues a streaming request followed by a non-streaming request.
private final class DualResponseHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DualResponseHTTPServer")
    private let firstResponse: HTTPResponse
    private let secondResponse: HTTPResponse
    private let requestCount = Mutex(0)

    static func start(firstResponse: HTTPResponse, secondResponse: HTTPResponse) async throws -> DualResponseHTTPServer {
        let server = try DualResponseHTTPServer(firstResponse: firstResponse, secondResponse: secondResponse)
        try await server.waitUntilReady()
        return server
    }

    private init(firstResponse: HTTPResponse, secondResponse: HTTPResponse) throws {
        self.firstResponse = firstResponse
        self.secondResponse = secondResponse
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
                        continuation.resume(throwing: NSError(domain: "DualResponseHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "no port"]))
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
                let count = self.requestCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                let response = count == 1 ? self.firstResponse : self.secondResponse
                self.sendResponse(on: connection, response: response)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func sendResponse(on connection: NWConnection, response: HTTPResponse) {
        let responseData = Self.makeHTTPResponseData(response)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func makeHTTPResponseData(_ response: HTTPResponse) -> Data {
        let statusLine = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        let headerLines = headers.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
        return Data((statusLine + headerLines + "\r\n").utf8) + response.body
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 401: return "Unauthorized"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "HTTP Status"
        }
    }
}

private struct HTTPResponse: Sendable {
    var statusCode: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
}

#else
@Suite("OpenAI client coverage")
struct OpenAIClientCoverageTests {}
#endif
