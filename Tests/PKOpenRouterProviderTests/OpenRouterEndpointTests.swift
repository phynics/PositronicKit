import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import PKOpenRouterProvider
import PKContracts
import PKTestSupport
import PKUtilities
import Testing

private typealias EndpointRecordingTransport = ScriptedProviderHTTPTransport

struct OpenRouterEndpointTests {
    private static let endpoints = [
        ("https://openrouter.ai", "https://openrouter.ai/api"),
        ("https://openrouter.ai/api", "https://openrouter.ai/api"),
        ("https://gateway.example/custom/openrouter", "https://gateway.example/custom/openrouter/api"),
    ]

    @Test("OpenRouter chat and model paths retain configured base paths")
    func chatAndModelPathsRetainConfiguredBasePaths() async throws {
        for (configuredEndpoint, expectedBaseURL) in Self.endpoints {
            let transport = EndpointRecordingTransport(responder: { request in
                if request.url?.path.hasSuffix("/models") == true {
                    return .data(Data(#"{"data":[]}"#.utf8), HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )!)
                }
                return .lines(["data: [DONE]"], HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!)
            })
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
