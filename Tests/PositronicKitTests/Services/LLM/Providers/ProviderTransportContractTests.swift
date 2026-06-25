import Foundation
import struct JSONSchema.Schema
@testable import PKOllamaProvider
@testable import PKOpenRouterProvider
import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

private actor TestProviderTransport: ProviderHTTPTransport {
    enum Response {
        case data(Data, HTTPURLResponse)
        case lines([String], HTTPURLResponse)
        case error(Error)
    }

    private(set) var requests: [URLRequest] = []
    var responder: @Sendable (URLRequest) -> Response

    init(responder: @escaping @Sendable (URLRequest) -> Response) {
        self.responder = responder
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        switch responder(request) {
        case let .data(data, response):
            return (data, response)
        case let .error(error):
            throw error
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
        case let .error(error):
            throw error
        case let .data(data, response):
            let string = String(decoding: data, as: UTF8.self)
            return (
                AsyncThrowingStream { continuation in
                    continuation.yield(string)
                    continuation.finish()
                },
                response
            )
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

@Suite("Provider transport contracts")
struct ProviderTransportContractTests {
    private func response(
        url: String,
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    @Test("OpenRouter transport exposes request URL, headers, body, and timeout")
    func openRouterRequestInspection() async throws {
        let transport = TestProviderTransport { _ in
            .lines([
                #"data: {"id":"chunk-1","model":"openai/gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"hi"}}]}"#,
                "data: [DONE]",
            ], self.response(url: "https://openrouter.ai/api/v1/chat/completions"))
        }

        let client = OpenRouterClient(
            apiKey: "secret",
            modelName: "openai/gpt-4o",
            timeoutInterval: 42,
            transport: transport,
            attribution: .init(applicationURL: "https://example.com/app", applicationTitle: "Example App")
        )

        let stream = await client.chatStream(messages: [LLMMessage(role: .user, content: "hello")], tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil)
        _ = try await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://example.com/app")
        #expect(request.value(forHTTPHeaderField: "X-Title") == "Example App")
        #expect(request.timeoutInterval == 42)
        #expect(request.httpBody != nil)
    }

    @Test("OpenRouter serializes a tools payload into the request body (YAK-23)")
    func openRouterToolsAreSerializedIntoBody() async throws {
        let transport = TestProviderTransport { _ in
            .lines([
                #"data: {"id":"chunk-1","model":"openai/gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"hi"}}]}"#,
                "data: [DONE]",
            ], self.response(url: "https://openrouter.ai/api/v1/chat/completions"))
        }
        let client = OpenRouterClient(apiKey: "secret", transport: transport)

        // A no-argument tool (like the app's `current_datetime`) is built from an empty object
        // schema. Confirm the tools payload still serializes into a non-nil body carrying the
        // tool with a `{"type":"object"}` parameters schema (regression for YAK-23, where the
        // request was suspected of being malformed — it is not).
        let emptyObjectSchema = ToolParameterSchema.object {}.schema
        let decodedSchema = try JSONDecoder().decode(Schema.self, from: JSONEncoder().encode(emptyObjectSchema))
        let noArgTool = LLMToolDefinition(name: "current_datetime", description: "Get the date/time", parameters: decodedSchema)

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "time?")],
            tools: [noArgTool],
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )
        _ = try await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        let body = try #require(request.httpBody, "request body was nil when tools were present")
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("current_datetime"))
        #expect(json.contains("\"type\":\"object\""))
    }

    @Test("OpenRouter attribution headers are omitted when not configured")
    func openRouterAttributionHeadersAreOptional() async throws {
        let transport = TestProviderTransport { _ in
            .lines([
                #"data: {"id":"chunk-1","model":"openai/gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"hi"}}]}"#,
                "data: [DONE]",
            ], self.response(url: "https://openrouter.ai/api/v1/chat/completions"))
        }

        let client = OpenRouterClient(apiKey: "secret", transport: transport, attribution: .init(applicationURL: nil, applicationTitle: nil))
        let stream = await client.chatStream(messages: [], tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil)
        _ = try await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Title") == nil)
    }

    @Test("OpenRouter stream tolerates malformed and truncated payloads without hanging")
    func openRouterMalformedAndTruncatedStream() async throws {
        let transport = TestProviderTransport { _ in
            .lines([
                "data: not-json",
                #"data: {"id":"chunk-1","model":"openai/gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"partial"}}]}"#,
            ], self.response(url: "https://openrouter.ai/api/v1/chat/completions"))
        }
        let client = OpenRouterClient(apiKey: "secret", transport: transport)
        let stream = await client.chatStream(messages: [], tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil)
        let chunks = try await stream.collect()
        #expect(chunks.count == 1)
        #expect(chunks.first?.choices.first?.delta.content == "partial")
    }

    @Test("OpenRouter model listing and malformed payload handling use injected transport")
    func openRouterModelListingAndMalformedPayload() async throws {
        let goodTransport = TestProviderTransport { request in
            .data(
                Data(#"{"data":[{"id":"z-model"},{"id":"a-model"}]}"#.utf8),
                self.response(url: request.url!.absoluteString)
            )
        }
        let goodClient = OpenRouterClient(apiKey: "secret", transport: goodTransport)
        let models = try await goodClient.fetchAvailableModels()
        #expect(models == ["a-model", "z-model"])

        let badTransport = TestProviderTransport { request in
            .data(Data(#"{"data":"wrong-shape"}"#.utf8), self.response(url: request.url!.absoluteString))
        }
        let badClient = OpenRouterClient(apiKey: "secret", transport: badTransport)
        await #expect(throws: DecodingError.self) {
            _ = try await badClient.fetchAvailableModels()
        }
    }

    @Test("Ollama transport exposes request URL, headers, body, and timeout")
    func ollamaRequestInspection() async throws {
        let transport = TestProviderTransport { _ in
            .lines([
                #"{"model":"llama3.1","message":{"role":"assistant","content":"hi"},"done":false}"#,
                #"{"model":"llama3.1","message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":1,"eval_count":1}"#,
            ], self.response(url: "http://localhost:11434/api/chat"))
        }

        let client = OllamaClient(
            endpoint: "http://localhost:11434",
            modelName: "llama3.1",
            timeoutInterval: 15,
            transport: transport
        )

        let stream = await client.chatStream(messages: [LLMMessage(role: .user, content: "hello")], tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil)
        _ = try await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 15)
        #expect(request.httpBody != nil)
    }

    @Test("Ollama stream tolerates malformed and truncated payloads without hanging")
    func ollamaMalformedAndTruncatedStream() async throws {
        let transport = TestProviderTransport { _ in
            .lines([
                "not-json",
                #"{"model":"llama3.1","message":{"role":"assistant","content":"partial"},"done":false}"#,
            ], self.response(url: "http://localhost:11434/api/chat"))
        }

        let client = OllamaClient(endpoint: "http://localhost:11434", modelName: "llama3.1", transport: transport)
        let stream = await client.chatStream(messages: [], tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil)
        let chunks = try await stream.collect()
        #expect(chunks.count == 1)
        #expect(chunks.first?.choices.first?.delta.content == "partial")
    }

    @Test("Ollama model listing and malformed payload handling use injected transport")
    func ollamaModelListingAndMalformedPayload() async throws {
        let goodTransport = TestProviderTransport { request in
            .data(
                Data(#"{"models":[{"name":"llama3.1"},{"name":"phi4"}]}"#.utf8),
                self.response(url: request.url!.absoluteString)
            )
        }
        let goodClient = OllamaClient(endpoint: "http://localhost:11434", modelName: "llama3.1", transport: goodTransport)
        let models = try await goodClient.fetchAvailableModels()
        #expect(models == ["llama3.1", "phi4"])

        let badTransport = TestProviderTransport { request in
            .data(Data(#"{"models":"wrong-shape"}"#.utf8), self.response(url: request.url!.absoluteString))
        }
        let badClient = OllamaClient(endpoint: "http://localhost:11434", modelName: "llama3.1", transport: badTransport)
        await #expect(throws: DecodingError.self) {
            _ = try await badClient.fetchAvailableModels()
        }
    }
}
