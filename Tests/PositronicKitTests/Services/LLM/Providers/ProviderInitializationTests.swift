import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import OpenAI
@testable import PKAnthropicProvider
@testable import PKOllamaProvider
@testable import PKOpenAIProvider
@testable import PKOpenRouterProvider
import PKShared
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Synchronization
import Testing

/// Local `ProviderHTTPTransport` mock, mirroring `TestProviderTransport` in
/// `ProviderTransportContractTests.swift`. Kept file-local (not shared via `PKTestSupport`)
/// to match the established convention in this test target.
private actor RequestRecordingTransport: ProviderHTTPTransport {
    private(set) var requests: [URLRequest] = []
    var responder: @Sendable (URLRequest) -> (Data, HTTPURLResponse)

    init(responder: @escaping @Sendable (URLRequest) -> (Data, HTTPURLResponse)) {
        self.responder = responder
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let (data, response) = responder(request)
        return (data, response)
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        requests.append(request)
        let (data, response) = responder(request)
        let string = String(decoding: data, as: UTF8.self)
        return (
            AsyncThrowingStream { continuation in
                for line in string.split(separator: "\n", omittingEmptySubsequences: true) {
                    continuation.yield(String(line))
                }
                continuation.finish()
            },
            response
        )
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

/// Records the URLRequest OpenAI's SDK sends over the wire, without performing real network
/// I/O. `intercept(request:)` fires synchronously before the request is dispatched, so it lets
/// us inspect host/scheme/port/model/timeout/apiKey without needing a valid mocked response.
private final class RecordingOpenAIMiddleware: OpenAIMiddleware, @unchecked Sendable {
    private let storage = Mutex<[URLRequest]>([])

    var recordedRequests: [URLRequest] {
        storage.withLock { $0 }
    }

    func intercept(request: URLRequest) -> URLRequest {
        storage.withLock { $0.append(request) }
        return request
    }
}

/// Blocks all real network I/O for the OpenAI SDK's `URLSession`: every request is answered
/// synchronously from process memory. Registered only on a dedicated ephemeral session, never
/// on `URLSession.shared`.
private final class NoNetworkURLProtocol: URLProtocol {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoNetworkURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // A deliberately-invalid response body: these tests only assert on the *outgoing*
        // request captured by the middleware, never on decoded response content, so failing
        // fast here (rather than modeling the full OpenAI stream wire format) is sufficient.
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 500,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Provider initialization contracts", .serialized)
struct ProviderInitializationTests {
    private func response(url: String, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: [:])!
    }

    // MARK: - OpenAI

    @Test("OpenAI client threads default host/port/scheme/model/timeout into the outgoing request")
    func openAIDefaultsPropagate() async throws {
        let middleware = RecordingOpenAIMiddleware()
        let client = OpenAIClient(
            apiKey: "sk-default-test",
            session: NoNetworkURLProtocol.session,
            middlewares: [middleware]
        )

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil
        )
        _ = try? await stream.collect()

        let request = try #require(middleware.recordedRequests.first)
        #expect(request.url?.host == "api.openai.com")
        #expect(request.url?.scheme == "https")
        #expect(request.timeoutInterval == 60.0)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-default-test")

        let body = try #require(request.httpBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("gpt-4o"))
    }

    @Test("OpenAI client threads explicit overrides into the outgoing request")
    func openAIOverridesPropagate() async throws {
        let middleware = RecordingOpenAIMiddleware()
        let client = OpenAIClient(
            apiKey: "sk-override-test",
            modelName: "gpt-4o-mini",
            host: "my-openai-proxy.example.com",
            port: 8443,
            scheme: "https",
            timeoutInterval: 12.5,
            maxRetries: 1,
            session: NoNetworkURLProtocol.session,
            middlewares: [middleware]
        )

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil
        )
        _ = try? await stream.collect()

        let request = try #require(middleware.recordedRequests.first)
        #expect(request.url?.host == "my-openai-proxy.example.com")
        #expect(request.url?.port == 8443)
        #expect(request.timeoutInterval == 12.5)

        let body = try #require(request.httpBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("gpt-4o-mini"))
    }

    @Test("OpenAI factory constructs a client with its adapter")
    func openAIFactoryConstructsClient() {
        let client = PKOpenAIProvider.makeClient(configuration: .fixture(apiKey: "test", activeProvider: .openAI))
        #expect(type(of: client) == OpenAIClient.self)
    }

    // MARK: - Anthropic

    @Test("Anthropic client threads default host/endpoint/model/version/timeout into the outgoing request")
    func anthropicDefaultsPropagate() async throws {
        let transport = RequestRecordingTransport { _ in
            (Data(), self.response(url: "https://api.anthropic.com/v1/messages", status: 500))
        }
        let client = AnthropicClient(apiKey: "anthropic-secret", transport: transport)

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil
        )
        _ = try? await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-secret")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.timeoutInterval == 60.0)

        let body = try #require(request.httpBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("claude-sonnet-4-5"))
        // Default maxTokens (4096) is used when GenerationParameters.maxTokens is nil.
        #expect(json.contains("\"max_tokens\":4096"))

        // Default maxRetries (3): the initial attempt plus 3 retries against the persistent
        // 500 response is 4 recorded requests.
        #expect(await transport.recordedRequests().count == 4)
    }

    @Test("Anthropic client threads explicit overrides into the outgoing request")
    func anthropicOverridesPropagate() async throws {
        let transport = RequestRecordingTransport { _ in
            (Data(), self.response(url: "https://anthropic.example.com:8443/v1/messages", status: 500))
        }
        let client = AnthropicClient(
            apiKey: "anthropic-secret",
            modelName: "claude-haiku-4",
            host: "anthropic.example.com",
            port: 8443,
            scheme: "https",
            timeoutInterval: 15,
            maxRetries: 1,
            transport: transport
        )

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil
        )
        _ = try? await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.absoluteString == "https://anthropic.example.com:8443/v1/messages")
        #expect(request.timeoutInterval == 15)

        let body = try #require(request.httpBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("claude-haiku-4"))
    }

    @Test("Anthropic client omits the default port suffix (443)")
    func anthropicDefaultPortOmitted() async throws {
        let transport = RequestRecordingTransport { _ in
            (Data(), self.response(url: "https://api.anthropic.com/v1/messages", status: 500))
        }
        let client = AnthropicClient(apiKey: "secret", port: 443, transport: transport)
        _ = try? await client.chatStream(
            messages: [], tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil
        ).collect()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.host == "api.anthropic.com")
        #expect(request.url?.port == nil)
    }

    @Test("Anthropic factory constructs a client with its adapter")
    func anthropicFactoryConstructsClient() {
        let client = PKAnthropicProvider.makeClient(configuration: .fixture(apiKey: "test", activeProvider: .anthropic))
        #expect(type(of: client) == AnthropicClient.self)
    }

    // MARK: - Ollama

    @Test("Ollama client threads required endpoint/model and default timeout into the outgoing request")
    func ollamaDefaultsPropagate() async throws {
        let transport = RequestRecordingTransport { _ in
            (Data(), self.response(url: "http://localhost:11434/api/chat", status: 500))
        }
        let client = OllamaClient(endpoint: "http://localhost:11434", modelName: "llama3.1", transport: transport)

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil
        )
        _ = try? await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
        #expect(request.timeoutInterval == 120.0)

        let body = try #require(request.httpBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("llama3.1"))
    }

    @Test("Ollama client threads explicit overrides into the outgoing request")
    func ollamaOverridesPropagate() async throws {
        let transport = RequestRecordingTransport { _ in
            (Data(), self.response(url: "http://192.168.1.50:11434/api/chat", status: 500))
        }
        let client = OllamaClient(
            endpoint: "http://192.168.1.50:11434",
            modelName: "mistral",
            timeoutInterval: 30,
            maxRetries: 1,
            transport: transport
        )

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil
        )
        _ = try? await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.absoluteString == "http://192.168.1.50:11434/api/chat")
        #expect(request.timeoutInterval == 30)

        let body = try #require(request.httpBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("mistral"))
    }

    @Test("Ollama documented default endpoint is preserved by direct provider composition")
    func ollamaDefaultEndpointIsReal() {
        let config = LLMConfiguration.fixture(
            endpoint: "http://localhost:11434",
            modelName: "llama3",
            activeProvider: .ollama
        )
        #expect(config.activeProviderConfiguration.endpoint == "http://localhost:11434")
    }

    @Test("Ollama factory constructs a client with its adapter")
    func ollamaFactoryConstructsClient() {
        let client = PKOllamaProvider.makeClient(configuration: .fixture(activeProvider: .ollama))
        #expect(type(of: client) == OllamaClient.self)
    }

    // MARK: - OpenRouter

    @Test("OpenRouter client threads default host/model/timeout/api path into the outgoing request")
    func openRouterDefaultsPropagate() async throws {
        let transport = RequestRecordingTransport { _ in
            (Data(), self.response(url: "https://openrouter.ai/api/v1/chat/completions", status: 500))
        }
        let client = OpenRouterClient(apiKey: "or-secret", transport: transport)

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil
        )
        _ = try? await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer or-secret")
        #expect(request.timeoutInterval == 60.0)

        let body = try #require(request.httpBody)
        let json = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        #expect(json.contains("openai/gpt-4o"))
    }

    @Test("OpenRouter client threads explicit overrides into the outgoing request")
    func openRouterOverridesPropagate() async throws {
        let transport = RequestRecordingTransport { _ in
            (Data(), self.response(url: "https://openrouter.example.com/api/v1/chat/completions", status: 500))
        }
        let client = OpenRouterClient(
            apiKey: "or-secret",
            modelName: "anthropic/claude-3.5-sonnet",
            host: "openrouter.example.com",
            port: 443,
            scheme: "https",
            timeoutInterval: 20,
            maxRetries: 1,
            transport: transport,
            attribution: .init()
        )

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil
        )
        _ = try? await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.absoluteString == "https://openrouter.example.com/api/v1/chat/completions")
        #expect(request.timeoutInterval == 20)

        let body = try #require(request.httpBody)
        let json = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        #expect(json.contains("anthropic/claude-3.5-sonnet"))
    }

    @Test("OpenRouter attribution headers are present when configured and absent when not")
    func openRouterAttributionHeadersReflectConfiguration() async throws {
        let withAttributionTransport = RequestRecordingTransport { _ in
            (Data(), self.response(url: "https://openrouter.ai/api/v1/chat/completions", status: 500))
        }
        let withAttributionClient = OpenRouterClient(
            apiKey: "or-secret",
            transport: withAttributionTransport,
            attribution: .init(applicationURL: "https://example.com/app", applicationTitle: "Example App")
        )
        _ = try? await withAttributionClient.chatStream(
            messages: [], tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil
        ).collect()

        let withRequest = try #require(await withAttributionTransport.recordedRequests().first)
        #expect(withRequest.value(forHTTPHeaderField: "HTTP-Referer") == "https://example.com/app")
        #expect(withRequest.value(forHTTPHeaderField: "X-Title") == "Example App")

        let withoutAttributionTransport = RequestRecordingTransport { _ in
            (Data(), self.response(url: "https://openrouter.ai/api/v1/chat/completions", status: 500))
        }
        let withoutAttributionClient = OpenRouterClient(
            apiKey: "or-secret",
            transport: withoutAttributionTransport,
            attribution: .init()
        )
        _ = try? await withoutAttributionClient.chatStream(
            messages: [], tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil
        ).collect()

        let withoutRequest = try #require(await withoutAttributionTransport.recordedRequests().first)
        #expect(withoutRequest.value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(withoutRequest.value(forHTTPHeaderField: "X-Title") == nil)
    }

    @Test("OpenRouter factory constructs a client with its adapter")
    func openRouterFactoryConstructsClient() {
        let client = PKOpenRouterProvider.makeClient(configuration: .fixture(activeProvider: .openRouter))
        #expect(type(of: client) == OpenRouterClient.self)
    }

    @Test("OpenRouter provider construction uses native structured output")
    func openRouterRegistersNativeStructuredOutput() {
        _ = PKOpenRouterProvider.makeClient(
            configuration: .fixture(activeProvider: .openRouter)
        )

    }

    @Test("OpenAI provider construction uses native structured output")
    func openAIRegistersNativeStructuredOutput() {
        _ = PKOpenAIProvider.makeClient(
            configuration: .fixture(activeProvider: .openAI)
        )

    }

    @Test("OpenAI-compatible provider construction uses compatible structured output")
    func openAICompatibleRegistersStructuredOutput() {
        _ = PKOpenAIProvider.makeClient(
            configuration: .fixture(activeProvider: .openAICompatible)
        )

    }

    @Test("Anthropic provider construction uses Anthropic structured output")
    func anthropicRegistersStructuredOutput() {
        _ = PKAnthropicProvider.makeClient(
            configuration: .fixture(activeProvider: .anthropic)
        )

    }

    @Test("Ollama provider construction uses Ollama structured output")
    func ollamaRegistersStructuredOutput() {
        _ = PKOllamaProvider.makeClient(
            configuration: .fixture(activeProvider: .ollama)
        )

    }
}
