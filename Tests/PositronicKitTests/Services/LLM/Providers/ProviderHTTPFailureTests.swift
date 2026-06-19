import Foundation
import Testing
import OpenAI
@testable import PKOpenAIProvider
@testable import PKOpenRouterProvider
@testable import PKOllamaProvider
@testable import PositronicKit

@Suite("Provider HTTP Failures")
struct ProviderHTTPFailureTests {
    @Test("OpenRouter omits retries for permanent HTTP failures")
    func openRouterPermanentFailureIsNotTransient() {
        let error = LLMServiceError.httpError(provider: "OpenRouter", statusCode: 401, responseBody: "unauthorized", retryAfter: nil)
        #expect(!RetryPolicy.isTransient(error: error))
    }

    @Test("Ollama retries transient HTTP failures")
    func ollamaTransientFailureIsTransient() {
        let error = LLMServiceError.httpError(provider: "Ollama", statusCode: 503, responseBody: "server error", retryAfter: nil)
        #expect(RetryPolicy.isTransient(error: error))
    }

    @Test("HTTP diagnostics remain bounded and sanitized")
    func httpDiagnosticsAreBounded() {
        let body = String(repeating: "x", count: 10_000)
        let error = LLMServiceError.httpError(provider: "OpenRouter", statusCode: 400, responseBody: body, retryAfter: nil)
        #expect(error.userFriendlyMessage.contains("OpenRouter"))
        #expect(error.userFriendlyMessage.contains("400"))
        #expect(!error.userFriendlyMessage.contains("Bearer "))
        #expect(error.userFriendlyMessage.count < 9_000)
    }

    @Test("OpenAI status errors are normalized into shared HTTP failures")
    func openAIStatusErrorsAreNormalized() {
        let client = OpenAIClient(apiKey: "test")
        let response = HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "3"]
        )!

        let mapped = client.mapProviderError(
            OpenAIError.statusError(response: response, statusCode: 429),
            provider: "OpenAI"
        )

        let error = try? #require(mapped as? LLMServiceError)
        #expect(error == .httpError(provider: "OpenAI", statusCode: 429, responseBody: "", retryAfter: 3))
        #expect(RetryPolicy.isTransient(error: mapped))
    }
}
