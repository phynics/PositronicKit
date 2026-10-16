import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging
@testable import PKAnthropicProvider
import PKContracts
import PKTestSupport
import PKUtilities
import Testing

/// Anthropic prompt-cache fixtures (#279).
@Suite("Anthropic prompt cache")
struct AnthropicPromptCacheTests {
    private static let stream = [
        #"data: {"type":"message_start","message":{"id":"msg_1","model":"claude-sonnet-4-5","usage":{"input_tokens":10,"cache_read_input_tokens":4,"cache_creation_input_tokens":6,"cache_creation":{"ephemeral_5m_input_tokens":6,"ephemeral_1h_input_tokens":0}}}}"#,
        #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}"#,
        #"data: {"type":"message_stop"}"#,
    ]

    private func makeClient(transport: ScriptedProviderHTTPTransport, model: String = "claude-sonnet-4-5") -> AnthropicClient {
        AnthropicClient(apiKey: "k", modelName: model, maxRetries: 0, transport: transport)
    }

    private let messages: [LLMMessage] = [
        LLMMessage(role: .system, content: "stable"),
        LLMMessage(role: .system, content: "semi"),
        LLMMessage(role: .user, content: "history q"),
        LLMMessage(role: .assistant, content: "history a"),
        LLMMessage(role: .system, content: "volatile"),
        LLMMessage(role: .user, content: "query"),
        LLMMessage(role: .assistant, content: "", toolCalls: [LLMToolCall(id: "call-1", name: "lookup", arguments: "{}")]),
        LLMMessage(role: .tool, content: "result", toolCallID: "call-1"),
    ]

    private func requestBody(
        model: String = "claude-sonnet-4-5",
        directive: PromptCacheDirective?
    ) async throws -> [String: Any] {
        let transport = ScriptedProviderHTTPTransport(lines: Self.stream)
        let client = makeClient(transport: transport, model: model)
        _ = try await client.chatStream(
            messages: messages,
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            responseModalities: [.text],
            audioOutput: nil,
            promptCache: directive
        ).collect()
        let request = try #require(await transport.lastRequest())
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test("system becomes a block array and all four tiers carry cache_control")
    func allFourTiersCarryMarkers() async throws {
        let directive = PromptCacheDirective(retention: .short, breakpoints: [
            .init(messageIndex: 0, tier: .stableSystem, estimatedPrefixTokens: 4_000),
            .init(messageIndex: 1, tier: .semiStableSystem, estimatedPrefixTokens: 5_000),
            .init(messageIndex: 3, tier: .history, estimatedPrefixTokens: 6_000),
            .init(messageIndex: 7, tier: .toolLoop, estimatedPrefixTokens: 9_000),
        ])
        let json = try await requestBody(directive: directive)

        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system.count == 2)
        #expect(system[0]["text"] as? String == "stable")
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect((system[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        // Short retention omits ttl, so the provider default (5m) applies.
        #expect((system[0]["cache_control"] as? [String: Any])?["ttl"] == nil)

        let outbound = try #require(json["messages"] as? [[String: Any]])
        // History assistant message carries the history marker.
        let history = outbound[1]
        let historyBlocks = try #require(history["content"] as? [[String: Any]])
        #expect((historyBlocks.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        // Tool result carries the tool-loop marker.
        let toolMessage = outbound.last
        let toolBlocks = try #require(toolMessage?["content"] as? [[String: Any]])
        #expect((toolBlocks.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        // Volatile system content moves onto the query user message, not the top-level system param.
        #expect(!system.contains { ($0["text"] as? String)?.contains("volatile") == true })
        let query = outbound[2]
        let queryBlocks = try #require(query["content"] as? [[String: Any]])
        #expect((queryBlocks.first?["text"] as? String)?.contains("<turn_context>") == true)
        #expect((queryBlocks.first?["text"] as? String)?.contains("volatile") == true)
    }

    @Test("extended retention requests the one-hour ttl")
    func extendedRetentionAddsTTL() async throws {
        let directive = PromptCacheDirective(retention: .extended, breakpoints: [
            .init(messageIndex: 0, tier: .stableSystem, estimatedPrefixTokens: 4_000),
        ])
        let json = try await requestBody(directive: directive)
        let system = try #require(json["system"] as? [[String: Any]])
        #expect((system[0]["cache_control"] as? [String: Any])?["ttl"] as? String == "1h")
    }

    @Test("a nil directive sends no cache fields")
    func disabledSendsNoCacheFields() async throws {
        let json = try await requestBody(directive: nil)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        #expect(!text.contains("cache_control"))
    }

    @Test("the tools tier marks the last tool definition when there is no stable system")
    func toolsTierMarksLastTool() async throws {
        let transport = ScriptedProviderHTTPTransport(lines: Self.stream)
        let client = makeClient(transport: transport)
        let tools = [
            LLMToolDefinition(name: "alpha", description: "a", parameters: nil, isStrict: nil),
            LLMToolDefinition(name: "beta", description: "b", parameters: nil, isStrict: nil),
        ]
        let directive = PromptCacheDirective(retention: .short, breakpoints: [
            .init(tier: .tools, estimatedPrefixTokens: 4_000),
        ])
        _ = try await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: tools,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            responseModalities: [.text],
            audioOutput: nil,
            promptCache: directive
        ).collect()

        let request = try #require(await transport.lastRequest())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let outboundTools = try #require(json["tools"] as? [[String: Any]])
        #expect(outboundTools[0]["cache_control"] == nil)
        #expect((outboundTools[1]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    @Test("breakpoints below the model minimum are dropped")
    func minimumPrefixSkipsSmallTier() async throws {
        let directive = PromptCacheDirective(retention: .short, breakpoints: [
            .init(messageIndex: 0, tier: .stableSystem, estimatedPrefixTokens: 100),
            .init(messageIndex: 3, tier: .history, estimatedPrefixTokens: 5_000),
        ])
        let json = try await requestBody(model: "claude-3-5-haiku", directive: directive)
        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system[0]["cache_control"] == nil)
    }

    @Test("usage parses cache read, write, and the retention breakdown")
    func usageParsesCacheAccounting() throws {
        let json = Data(#"{"id":"msg_2","model":"claude-sonnet-4-5","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":4,"cache_creation_input_tokens":6,"cache_creation":{"ephemeral_5m_input_tokens":6,"ephemeral_1h_input_tokens":0}}}"#.utf8)
        let response = try JSONDecoder().decode(AnthropicChatResponse.self, from: json)
        let details = try #require(response.usage?.promptDetails)
        #expect(details.cachedTokens == 4)
        #expect(details.cacheWriteTokens == 6)
        #expect(details.cacheWriteBreakdown == [.short: 6, .extended: 0])
    }

    @Test("capability declares the four-breakpoint explicit mechanism")
    func capabilityIsExplicit() {
        let client = makeClient(transport: ScriptedProviderHTTPTransport())
        #expect(client.promptCachingCapability == .explicit(maxBreakpoints: 4))
    }
}
