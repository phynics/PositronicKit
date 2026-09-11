import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import PKOllamaProvider
import PKContracts
import PKTestSupport
import Testing

@Suite("Ollama provider errors")
struct OllamaErrorTests {
    @Test("Non-success responses map to the typed Ollama HTTP error")
    func nonSuccessResponseMapsToTypedHTTPError() async throws {
        let response = HTTPURLResponse(
            url: URL(string: "http://localhost:11434/api/chat")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/x-ndjson"]
        )!
        let transport = ScriptedProviderHTTPTransport(responses: [
            .lines([#"{"error":"busy"}"#], response),
        ])
        let client = OllamaClient(
            endpoint: "http://localhost:11434",
            modelName: "fixture",
            maxRetries: 0,
            transport: transport
        )

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
            #expect(provider == "Ollama")
            #expect(statusCode == 503)
            #expect(retryAfter == nil)
        }
    }
}
