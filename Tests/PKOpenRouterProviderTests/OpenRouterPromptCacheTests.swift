import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import PKOpenRouterProvider
import PKContracts
import PKTestSupport
import PKUtilities
import Testing

/// OpenRouter prompt-cache fixtures (#279).
@Suite("OpenRouter prompt cache")
struct OpenRouterPromptCacheTests {
    private static let completion = Data(#"{"id":"r","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}"#.utf8)

    private func makeClient(transport: ScriptedProviderHTTPTransport, model: String) -> OpenRouterClient {
        OpenRouterClient(apiKey: "k", modelName: model, maxRetries: 0, transport: transport)
    }

    private func requestBody(model: String, directive: PromptCacheDirective?) async throws -> [String: Any] {
        let transport = ScriptedProviderHTTPTransport(responses: [.dataResponse(Self.completion)])
        let client = makeClient(transport: transport, model: model)
        _ = try await client.chatCompletion(
            messages: [
                LLMMessage(role: .system, content: "stable"),
                LLMMessage(role: .user, content: "hi"),
            ],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            responseModalities: [.text],
            audioOutput: nil,
            promptCache: directive
        )
        let request = try #require(await transport.lastRequest())
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test("routing key becomes session_id for sticky routing")
    func routingKeyBecomesSessionID() async throws {
        let directive = PromptCacheDirective(routingKey: "routekey", retention: .short)
        let json = try await requestBody(model: "openai/gpt-4o", directive: directive)
        #expect(json["session_id"] as? String == "routekey")
    }

    @Test("Anthropic-routed models carry cache_control on marked content")
    func anthropicRouteCarriesCacheControl() async throws {
        let directive = PromptCacheDirective(routingKey: "routekey", retention: .extended, breakpoints: [
            .init(messageIndex: 0, tier: .stableSystem, estimatedPrefixTokens: 4_000),
        ])
        let json = try await requestBody(model: "anthropic/claude-sonnet-4-5", directive: directive)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let system = try #require(messages.first)
        let blocks = try #require(system["content"] as? [[String: Any]])
        #expect((blocks.last?["cache_control"] as? [String: Any])?["ttl"] as? String == "1h")
    }

    @Test("every Anthropic tier lands on its message content block")
    func allTiersLandOnMessageBlocks() async throws {
        let transport = ScriptedProviderHTTPTransport(responses: [.dataResponse(Self.completion)])
        let client = makeClient(transport: transport, model: "anthropic/claude-sonnet-4-5")
        let directive = PromptCacheDirective(retention: .short, breakpoints: [
            .init(messageIndex: 0, tier: .stableSystem, estimatedPrefixTokens: 2_000),
            .init(messageIndex: 1, tier: .semiStableSystem, estimatedPrefixTokens: 3_000),
            .init(messageIndex: 3, tier: .history, estimatedPrefixTokens: 5_000),
            .init(messageIndex: 4, tier: .toolLoop, estimatedPrefixTokens: 6_000),
        ])
        _ = try await client.chatCompletion(
            messages: [
                LLMMessage(role: .system, content: "stable"),
                LLMMessage(role: .system, content: "semi"),
                LLMMessage(role: .user, content: "history q"),
                LLMMessage(role: .assistant, content: "history a"),
                LLMMessage(role: .tool, content: "result", toolCallID: "call-1"),
            ],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            responseModalities: [.text],
            audioOutput: nil,
            promptCache: directive
        )
        let request = try #require(await transport.lastRequest())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        func lastBlockCarriesMarker(_ message: [String: Any]) -> Bool {
            guard let blocks = message["content"] as? [[String: Any]] else { return false }
            return (blocks.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral"
        }

        #expect(lastBlockCarriesMarker(messages[0]))
        #expect(lastBlockCarriesMarker(messages[1]))
        #expect(lastBlockCarriesMarker(messages[3]))
        #expect(lastBlockCarriesMarker(messages[4]))
        // The unmarked query message between history and the tool loop carries no marker.
        #expect(!lastBlockCarriesMarker(messages[2]))
    }

    @Test("a nil directive sends no cache fields")
    func nilDirectiveSendsNoCacheFields() async throws {
        let json = try await requestBody(model: "anthropic/claude-sonnet-4-5", directive: nil)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        #expect(!text.contains("cache_control"))
        #expect(json["session_id"] == nil)
    }

    @Test("non-Anthropic routes rely on automatic caching and send no cache_control")
    func nonAnthropicRouteHasNoCacheControl() async throws {
        let directive = PromptCacheDirective(routingKey: "routekey", retention: .short, breakpoints: [
            .init(messageIndex: 0, tier: .stableSystem, estimatedPrefixTokens: 4_000),
        ])
        let json = try await requestBody(model: "openai/gpt-4o", directive: directive)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        #expect(!text.contains("cache_control"))
        #expect(json["session_id"] as? String == "routekey")
    }

    @Test("capability is explicit only for Anthropic routes")
    func capabilityDependsOnRoute() {
        let anthropic = makeClient(transport: ScriptedProviderHTTPTransport(), model: "anthropic/claude-sonnet-4-5")
        #expect(anthropic.promptCachingCapability == .explicit(maxBreakpoints: 4))
        let openai = makeClient(transport: ScriptedProviderHTTPTransport(), model: "openai/gpt-4o")
        #expect(openai.promptCachingCapability == .automatic)
    }

    @Test("usage parses cache-write tokens and cache discount stays parsed")
    func usageParsesCacheAccounting() throws {
        let json = #"{"id":"r","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12,"cache_discount":0.25,"prompt_tokens_details":{"cached_tokens":4,"cache_write_tokens":6}}}"#
        let response = try JSONDecoder().decode(OpenRouterChatResponse.self, from: Data(json.utf8))
        let details = try #require(response.toLLMStreamChunk().usage?.promptTokensDetails)
        #expect(details.cachedTokens == 4)
        #expect(details.cacheWriteTokens == 6)
        #expect(response.usage?.cacheDiscount == 0.25)
    }
}
