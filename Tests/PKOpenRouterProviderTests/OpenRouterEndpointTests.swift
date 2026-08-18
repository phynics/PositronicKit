import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import PKOpenRouterProvider
import PKShared
import PKUtilities
import Testing

private actor EndpointRecordingTransport: ProviderHTTPTransport {
    private var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return (Data(#"{"data":[]}"#.utf8), response(for: request))
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        requests.append(request)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("data: [DONE]")
            continuation.finish()
        }
        return (stream, response(for: request))
    }

    func requestURLs() -> [URL] {
        requests.compactMap(\.url)
    }

    private func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

struct OpenRouterEndpointTests {
    private static let endpoints = [
        ("https://openrouter.ai", "https://openrouter.ai/api"),
        ("https://openrouter.ai/api", "https://openrouter.ai/api"),
        ("https://gateway.example/custom/openrouter", "https://gateway.example/custom/openrouter/api"),
    ]

    @Test("OpenRouter chat and model paths retain configured base paths")
    func chatAndModelPathsRetainConfiguredBasePaths() async throws {
        for (configuredEndpoint, expectedBaseURL) in Self.endpoints {
            let transport = EndpointRecordingTransport()
            let client = OpenRouterClient(
                apiKey: "test",
                baseURL: URL(string: configuredEndpoint)!,
                maxRetries: 0,
                transport: transport
            )

            let stream = await client.chatStream(
                messages: [LLMMessage(role: .user, content: "hello")],
                tools: nil,
                toolChoice: nil,
                responseFormat: nil,
                generationParameters: nil
            )
            for try await _ in stream {}
            _ = try await client.fetchAvailableModels()

            let requestURLs = await transport.requestURLs()
            #expect(requestURLs.map(\.absoluteString) == [
                "\(expectedBaseURL)/v1/chat/completions",
                "\(expectedBaseURL)/v1/models",
            ])
        }
    }

    @Test("OpenRouter factory preserves configured base paths")
    func factoryPreservesConfiguredBasePaths() async {
        for (configuredEndpoint, expectedBaseURL) in Self.endpoints {
            var configuration = LLMConfiguration.openRouter
            configuration.providers[.openRouter]?.endpoint = configuredEndpoint

            let client = PKOpenRouterProvider.makeClient(
                configuration: configuration
            )

            let currentBaseURL = await client.currentBaseURL
            #expect(currentBaseURL.absoluteString == expectedBaseURL)
        }
    }
}
