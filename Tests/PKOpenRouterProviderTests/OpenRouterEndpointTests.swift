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

            let client = PKOpenRouter.makeClient(
                configuration: configuration
            )

            let currentBaseURL = await client.currentBaseURL
            #expect(currentBaseURL.absoluteString == expectedBaseURL)
        }
    }

    @Test("Native chat completion maps the full response without streaming")
    func nativeChatCompletionMapsResponse() async throws {
        let transport = EndpointRecordingTransport(responder: { request in
            .data(Data(#"{"id":"response-1","model":"vendor/model","choices":[{"index":0,"message":{"role":"assistant","content":"hello","reasoning":"thinking","audio":{"id":"audio-1","data":"AQID","transcript":"hello","expires_at":2000000000},"tool_calls":[{"id":"call-1","type":"function","function":{"name":"lookup","arguments":"{\"city\":\"Paris\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5,"prompt_tokens_details":{"cached_tokens":1}}}"#.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        })
        let client: any LLMClientProtocol = OpenRouterClient(apiKey: "test", maxRetries: 0, transport: transport)

        let response = try await client.chatCompletion(
            messages: [LLMMessage(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            responseModalities: [.text, .audio],
            audioOutput: .init(format: .wav, voice: "alloy")
        )

        #expect(response.id == "response-1")
        #expect(response.choices.first?.delta.content == "hello")
        #expect(response.choices.first?.delta.reasoning == "thinking")
        #expect(response.choices.first?.delta.toolCalls?.first?.function?.name == "lookup")
        #expect(response.choices.first?.delta.toolCalls?.first?.function?.arguments == #"{"city":"Paris"}"#)
        #expect(response.choices.first?.delta.audio == .init(
            data: Data([1, 2, 3]), format: .wav, transcript: "hello",
            continuation: .init(provider: .openRouter, id: "audio-1", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        ))
        #expect(response.choices.first?.finishReason == "tool_calls")
        #expect(response.usage?.totalTokens == 5)
        #expect(response.usage?.promptTokensDetails?.cachedTokens == 1)
        let request = try #require(await transport.lastRequest())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["stream"] as? Bool == false)
        #expect(json["stream_options"] == nil)
        #expect(json["modalities"] as? [String] == ["text", "audio"])
        #expect(json["audio"] as? [String: String] == ["format": "wav", "voice": "alloy"])
    }

    @Test("Native completion retries a transient error once, then returns success")
    func nativeCompletionRetries() async throws {
        let transport = ScriptedProviderHTTPTransport(responses: [
            .error(URLError(.timedOut)),
            .dataResponse(Data(#"{"id":"id","model":"model","choices":[{"index":0,"message":{"role":"assistant","content":"success"},"finish_reason":"stop"}]}"#.utf8)),
        ])
        let client: any LLMClientProtocol = OpenRouterClient(apiKey: "test", maxRetries: 1, transport: transport)
        #expect(try await client.sendMessage("hi") == "success")
        #expect(await transport.requestCount() == 2)
    }

    @Test("Native completion surfaces non-2xx without retrying client errors")
    func nativeCompletionHTTPError() async throws {
        let transport = ScriptedProviderHTTPTransport(responses: [.dataResponse(Data("denied".utf8), statusCode: 403)])
        let client: any LLMClientProtocol = OpenRouterClient(apiKey: "test", maxRetries: 1, transport: transport)
        await #expect(throws: LLMServiceError.httpError(provider: "OpenRouter", statusCode: 403, responseBody: "denied", retryAfter: nil)) {
            _ = try await client.chatCompletion(messages: [], tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil)
        }
        #expect(await transport.requestCount() == 1)
    }
}
