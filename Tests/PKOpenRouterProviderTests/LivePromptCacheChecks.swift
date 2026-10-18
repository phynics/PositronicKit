import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import PKContracts
import PKOpenRouterProvider
import PKTestSupport
import Testing

/// Opt-in live check that the OpenRouter adapter's Anthropic-routed `cache_control` breakpoints
/// produce a real provider-side cache hit. Off unless both opt-ins are set:
///
/// - `POSITRONICKIT_LIVE_TESTS=1`
/// - `OPENROUTER_API_KEY` (and optionally `POSITRONICKIT_LIVE_OPENROUTER_MODEL`)
///
/// The default gate never runs it, so ordinary `swift test` and fork pull requests stay
/// network-free and deterministic. The nightly live workflow turns both on. This suite is
/// report-only by design: it asserts the property, and the workflow keeps the job green.
@Suite(
    "Live OpenRouter prompt cache",
    .enabled(if: LivePromptCacheEnvironment.isEnabled(key: "OPENROUTER_API_KEY"))
)
struct LiveOpenRouterPromptCacheChecks {
    @Test("a repeated stable prefix reports cached read tokens on an Anthropic-routed model")
    func repeatedPrefixReportsCachedReadTokens() async throws {
        let apiKey = try #require(LivePromptCacheEnvironment.value(key: "OPENROUTER_API_KEY"))
        // OpenRouter forwards prompt caching for the Anthropic models it routes, which is the
        // path `OpenRouterPromptCache.isAnthropicRouted` marks with `cache_control`.
        let model = LivePromptCacheEnvironment.value(key: "POSITRONICKIT_LIVE_OPENROUTER_MODEL")
            ?? "anthropic/claude-sonnet-4.5"
        let client = OpenRouterClient(apiKey: apiKey, modelName: model, maxRetries: 1)

        let directive = PromptCacheDirective(retention: .short, breakpoints: [
            PromptCacheBreakpoint(messageIndex: 0, tier: .stableSystem, estimatedPrefixTokens: 2048),
        ])
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: LivePromptCacheEnvironment.stablePrefix()),
            LLMMessage(role: .user, content: "Reply with the single word ok."),
        ]

        // The first round writes the cache; the second must read it. Same content both times.
        _ = try await round(client: client, messages: messages, directive: directive)
        let usage = try await round(client: client, messages: messages, directive: directive)

        let cachedTokens = usage?.promptTokensDetails?.cachedTokens ?? 0
        #expect(
            cachedTokens > 0,
            "OpenRouter reported cachedTokens=\(cachedTokens) on the repeated prefix; usage=\(String(describing: usage))"
        )
    }

    private func round(
        client: OpenRouterClient,
        messages: [LLMMessage],
        directive: PromptCacheDirective
    ) async throws -> LLMTokenUsage? {
        let chunks = try await client.chatStream(
            messages: messages,
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            responseModalities: [.text],
            audioOutput: nil,
            promptCache: directive
        ).collect()
        return LLMStreamChunk.folding(chunks)?.usage
    }
}

/// Shared opt-in reads for the live prompt-cache suites.
private enum LivePromptCacheEnvironment {
    static func isEnabled(key: String) -> Bool {
        guard value(key: "POSITRONICKIT_LIVE_TESTS") == "1" else { return false }
        return value(key: key) != nil
    }

    static func value(key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }

    /// A deterministic prefix long enough to cross Anthropic's 1024-token minimum. The exact
    /// token count does not matter; stability across the two rounds does.
    static func stablePrefix() -> String {
        String(repeating: "The reference record states the same value for every run. ", count: 220)
    }
}
