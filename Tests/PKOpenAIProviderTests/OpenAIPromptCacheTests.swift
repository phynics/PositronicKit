import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import PKOpenAIProvider
import PKContracts
import PKUtilities
import Testing

/// OpenAI prompt-cache fixtures (#279).
@Suite("OpenAI prompt cache")
struct OpenAIPromptCacheTests {
    private func chatRequest(directive: PromptCacheDirective?, model: String = "gpt-4o") throws -> [String: Any] {
        let client = OpenAIClient(apiKey: "k", modelName: model, host: "api.openai.com", api: .chatCompletions)
        let request = try client.makeChatRequest(
            messages: [.init(role: .user, content: "hi")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            responseModalities: [.text],
            audioOutput: nil,
            promptCache: directive,
            stream: false
        )
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func responsesRequest(directive: PromptCacheDirective?, model: String = "gpt-4o") throws -> [String: Any] {
        let client = OpenAIClient(apiKey: "k", modelName: model, host: "api.openai.com", api: .responses)
        let request = try client.makeResponsesRequest(
            messages: [.init(role: .user, content: "hi")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            promptCache: directive,
            stream: false
        )
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test("Chat Completions carries the routing key and short retention")
    func chatCompletionsKeyAndShortRetention() throws {
        let directive = PromptCacheDirective(routingKey: "routekey", retention: .short)
        let json = try chatRequest(directive: directive)
        #expect(json["prompt_cache_key"] as? String == "routekey")
        #expect(json["prompt_cache_retention"] as? String == "in_memory")
    }

    @Test("extended retention requests the 24-hour window")
    func extendedRetention() throws {
        let directive = PromptCacheDirective(routingKey: "routekey", retention: .extended)
        let json = try chatRequest(directive: directive)
        #expect(json["prompt_cache_retention"] as? String == "24h")
    }

    @Test("models without retention support omit the field but keep the key")
    func unsupportedModelOmitsRetention() throws {
        let directive = PromptCacheDirective(routingKey: "routekey", retention: .short)
        let json = try chatRequest(directive: directive, model: "custom-local-model")
        #expect(json["prompt_cache_key"] as? String == "routekey")
        #expect(json["prompt_cache_retention"] == nil)
    }

    @Test("the Responses request carries the same cache fields")
    func responsesCarriesCacheFields() throws {
        let directive = PromptCacheDirective(routingKey: "routekey", retention: .extended)
        let json = try responsesRequest(directive: directive)
        #expect(json["prompt_cache_key"] as? String == "routekey")
        #expect(json["prompt_cache_retention"] as? String == "24h")
    }

    @Test("a nil directive produces no cache fields")
    func nilDirectiveProducesNoFields() throws {
        let chat = try chatRequest(directive: nil)
        #expect(chat["prompt_cache_key"] == nil)
        #expect(chat["prompt_cache_retention"] == nil)
        let responses = try responsesRequest(directive: nil)
        #expect(responses["prompt_cache_key"] == nil)
        #expect(responses["prompt_cache_retention"] == nil)
    }

    @Test("Chat Completions usage parses cached and cache-write tokens")
    func chatCompletionsUsage() throws {
        let json = #"{"id":"c","object":"chat.completion.chunk","created":0,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_tokens_details":{"cached_tokens":3,"cache_write_tokens":7}}}"#
        let result = try JSONDecoder().decode(ChatCompletionsStreamChunk.self, from: Data(json.utf8))
        let details = try #require(result.toLLMStreamChunk().usage?.promptTokensDetails)
        #expect(details.cachedTokens == 3)
        #expect(details.cacheWriteTokens == 7)
    }

    @Test("Responses usage parses cached and cache-write tokens")
    func responsesUsage() throws {
        var accumulator = ResponsesStreamAccumulator()
        let payload = try JSONSerialization.data(withJSONObject: [
            "type": "response.completed",
            "usage": [
                "input_tokens": 10,
                "output_tokens": 5,
                "total_tokens": 15,
                "cache_write_tokens": 6,
                "input_tokens_details": ["cached_tokens": 4],
            ],
        ])
        let chunk = ResponsesEvents.chunk(
            forEventType: "response.completed",
            payload: payload,
            model: "gpt-5",
            responseID: "r",
            accumulator: &accumulator
        )
        let details = try #require(chunk?.usage?.promptTokensDetails)
        #expect(details.cachedTokens == 4)
        #expect(details.cacheWriteTokens == 6)
    }

    @Test("capability declares automatic prefix caching")
    func capabilityIsAutomatic() {
        let client = OpenAIClient(apiKey: "k")
        #expect(client.promptCachingCapability == .automatic)
    }
}
