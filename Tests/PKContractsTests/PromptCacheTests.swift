import Foundation
import PKContracts
import Testing

@Suite("Prompt cache contracts")
struct PromptCacheTests {
    @Test("directive and breakpoint round-trip through Codable")
    func directiveRoundTrips() throws {
        let original = PromptCacheDirective(
            routingKey: "0123456789abcdef0123456789abcdef",
            retention: .extended,
            breakpoints: [
                PromptCacheBreakpoint(tier: .tools, estimatedPrefixTokens: 120),
                PromptCacheBreakpoint(messageIndex: 4, tier: .stableSystem, estimatedPrefixTokens: 900),
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PromptCacheDirective.self, from: data)

        #expect(decoded == original)
        #expect(decoded.breakpoints.map(\.tier) == [.tools, .stableSystem])
        #expect(decoded.breakpoints[0].messageIndex == nil)
    }

    @Test("a directive with no routing key or breakpoints round-trips")
    func emptyDirectiveRoundTrips() throws {
        let original = PromptCacheDirective(retention: .short)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PromptCacheDirective.self, from: data)
        #expect(decoded == original)
        #expect(decoded.routingKey == nil)
        #expect(decoded.breakpoints.isEmpty)
    }

    @Test("prompt details round-trip cache read and write fields")
    func promptDetailsRoundTrip() throws {
        let original = LLMTokenUsagePromptDetails(
            cachedTokens: 10,
            cacheWriteTokens: 5,
            cacheWriteBreakdown: [.short: 3, .extended: 2]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMTokenUsagePromptDetails.self, from: data)

        #expect(decoded == original)
        #expect(decoded.cacheWriteBreakdown == [.short: 3, .extended: 2])
    }

    @Test("cache-write breakdown encodes as a retention-keyed JSON object")
    func cacheWriteBreakdownEncodesAsObject() throws {
        let details = LLMTokenUsagePromptDetails(
            cachedTokens: nil,
            cacheWriteTokens: 5,
            cacheWriteBreakdown: [.short: 3, .extended: 2]
        )
        let data = try JSONEncoder().encode(details)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let breakdown = try #require(object["cache_write_breakdown"] as? [String: Int])
        #expect(breakdown == ["short": 3, "extended": 2])
    }

    @Test("legacy prompt details without cache-write fields decode with nil")
    func legacyPromptDetailsDecode() throws {
        // The exact shape produced before cache-write accounting existed.
        let legacy = Data(#"{"cached_tokens":12}"#.utf8)
        let decoded = try JSONDecoder().decode(LLMTokenUsagePromptDetails.self, from: legacy)

        #expect(decoded.cachedTokens == 12)
        #expect(decoded.cacheWriteTokens == nil)
        #expect(decoded.cacheWriteBreakdown == nil)
    }

    @Test("legacy token usage decodes with nil prompt-detail cache fields")
    func legacyTokenUsageDecodes() throws {
        let legacy = Data(
            #"{"prompt_tokens":20,"completion_tokens":5,"total_tokens":25,"prompt_tokens_details":{"cached_tokens":4}}"#.utf8
        )
        let decoded = try JSONDecoder().decode(LLMTokenUsage.self, from: legacy)

        #expect(decoded.promptTokensDetails?.cachedTokens == 4)
        #expect(decoded.promptTokensDetails?.cacheWriteTokens == nil)
        #expect(decoded.promptTokensDetails?.cacheWriteBreakdown == nil)
    }

    @Test("prompt-caching capabilities compare by mechanism")
    func capabilityEquality() {
        #expect(PromptCachingCapability.none == .none)
        #expect(PromptCachingCapability.automatic == .automatic)
        #expect(PromptCachingCapability.explicit(maxBreakpoints: 4) == .explicit(maxBreakpoints: 4))
        #expect(PromptCachingCapability.explicit(maxBreakpoints: 4) != .explicit(maxBreakpoints: 3))
        #expect(PromptCachingCapability.none != .automatic)
    }
}
