import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import PKContracts
import PKOpenAIProvider
import PKTestSupport
import Testing

/// Opt-in live check that the OpenAI adapter's stable prefix produces a real provider-side
/// cache hit. Off unless both opt-ins are set:
///
/// - `POSITRONICKIT_LIVE_TESTS=1`
/// - `OPENAI_API_KEY` (and optionally `POSITRONICKIT_LIVE_OPENAI_MODEL`)
///
/// The default gate never runs it, so ordinary `swift test` and fork pull requests stay
/// network-free and deterministic. The nightly live workflow turns both on. This suite is
/// report-only by design: it asserts the property, and the workflow keeps the job green.
@Suite(
    "Live OpenAI prompt cache",
    .enabled(if: LivePromptCacheEnvironment.isEnabled(key: "OPENAI_API_KEY"))
)
struct LiveOpenAIPromptCacheChecks {
    @Test("a repeated stable prefix reports cached read tokens")
    func repeatedPrefixReportsCachedReadTokens() async throws {
        let apiKey = try #require(LivePromptCacheEnvironment.value(key: "OPENAI_API_KEY"))
        let model = LivePromptCacheEnvironment.value(key: "POSITRONICKIT_LIVE_OPENAI_MODEL") ?? "gpt-4o"
        let client = OpenAIClient(apiKey: apiKey, modelName: model, maxRetries: 1)

        // OpenAI caches the longest matching prefix automatically; the routing key only keeps
        // related requests on one cache shard, so a stable value is enough here.
        let directive = PromptCacheDirective(
            routingKey: "positronickit-live-cache-check",
            retention: .short
        )
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
            "OpenAI reported cachedTokens=\(cachedTokens) on the repeated prefix; usage=\(String(describing: usage))"
        )
    }

    private func round(
        client: OpenAIClient,
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

    /// A deterministic prefix long enough to cross OpenAI's 1024-token minimum. The exact token
    /// count does not matter; stability across the two rounds does.
    static func stablePrefix() -> String {
        String(repeating: "The reference record states the same value for every run. ", count: 220)
    }
}
