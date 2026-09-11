import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import PKAnthropicProvider
import PKContracts
import PKTestSupport
import Testing

@Suite("Anthropic provider errors")
struct AnthropicErrorTests {
    @Test("Non-success responses map to the typed Anthropic HTTP error")
    func nonSuccessResponseMapsToTypedHTTPError() async throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        let transport = ScriptedProviderHTTPTransport(responses: [
            .lines([#"data: {"type":"error","error":{"type":"authentication_error","message":"invalid key"}}"#], response),
        ])
        let client = AnthropicClient(apiKey: "secret", maxRetries: 0, transport: transport)

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
            #expect(provider == "Anthropic")
            #expect(statusCode == 401)
            #expect(retryAfter == nil)
        }
    }
}
