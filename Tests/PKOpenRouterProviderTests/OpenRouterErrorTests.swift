import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import PKOpenRouterProvider
import PKContracts
import PKTestSupport
import Testing

@Suite("OpenRouter provider errors")
struct OpenRouterErrorTests {
    @Test("Non-success responses map to the typed OpenRouter HTTP error")
    func nonSuccessResponseMapsToTypedHTTPError() async throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream", "Retry-After": "2"]
        )!
        let transport = ScriptedProviderHTTPTransport(responses: [
            .lines([#"data: {"error":{"message":"rate limited"}}"#], response),
        ])
        let client = OpenRouterClient(apiKey: "secret", maxRetries: 0, transport: transport)

        do {
            _ = try await client.chatStream(
                messages: [LLMMessage(role: .user, content: "hello")],
                tools: nil,
                toolChoice: nil,
                responseFormat: nil,
                generationParameters: nil
            ).collect()
            Issue.record("Expected the non-success response to throw")
        } catch let error as LLMServiceError {
            guard case let .httpError(provider, statusCode, _, retryAfter) = error else {
                Issue.record("Expected LLMServiceError.httpError, got \(error)")
                return
            }
            #expect(provider == "OpenRouter")
            #expect(statusCode == 429)
            #expect(retryAfter == 2)
        }
    }
}
