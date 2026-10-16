import Foundation
import PKContracts
@testable import PKUtilities
import Testing

@Suite("Prompt cache planner")
struct PromptCachePlannerTests {
    private func breakpoint(
        _ tier: PromptCacheBreakpoint.Tier,
        index: Int? = nil,
        tokens: Int = 2_000
    ) -> PromptCacheBreakpoint {
        PromptCacheBreakpoint(messageIndex: index, tier: tier, estimatedPrefixTokens: tokens)
    }

    private func directive(_ breakpoints: [PromptCacheBreakpoint]) -> PromptCacheDirective {
        PromptCacheDirective(
            routingKey: "0123456789abcdef0123456789abcdef",
            retention: .extended,
            breakpoints: breakpoints
        )
    }

    @Test("plans breakpoints in request order")
    func ordersByRequestPosition() {
        let plan = PromptCachePlanner.plan(
            directive([
                breakpoint(.toolLoop, index: 7),
                breakpoint(.stableSystem, index: 0),
                breakpoint(.history, index: 3),
                breakpoint(.semiStableSystem, index: 1),
            ]),
            maxBreakpoints: 4
        )

        #expect(plan.breakpoints.map(\.tier) == [.stableSystem, .semiStableSystem, .history, .toolLoop])
        #expect(plan.retention == .extended)
        #expect(plan.routingKey == "0123456789abcdef0123456789abcdef")
    }

    @Test("the cap drops semiStableSystem before history and never toolLoop")
    func capDropsLowestValueFirst() {
        let plan = PromptCachePlanner.plan(
            directive([
                breakpoint(.stableSystem, index: 0),
                breakpoint(.semiStableSystem, index: 1),
                breakpoint(.history, index: 3),
                breakpoint(.toolLoop, index: 7),
                breakpoint(.tools, tokens: 500),
            ]),
            maxBreakpoints: 4
        )

        #expect(plan.breakpoints.count == 4)
        #expect(!plan.breakpoints.contains { $0.tier == .semiStableSystem })
        #expect(plan.breakpoints.contains { $0.tier == .history })
        #expect(plan.breakpoints.contains { $0.tier == .toolLoop })
    }

    @Test("breakpoints below the minimum prefix are skipped")
    func skipsBelowMinimumPrefix() {
        let plan = PromptCachePlanner.plan(
            directive([
                breakpoint(.stableSystem, index: 0, tokens: 300),
                breakpoint(.semiStableSystem, index: 1, tokens: 1_500),
                breakpoint(.history, index: 3, tokens: 5_000),
            ]),
            maxBreakpoints: 4,
            minimumPrefixTokens: 1_024
        )

        #expect(plan.breakpoints.map(\.tier) == [.semiStableSystem, .history])
    }

    @Test("a repeated tier keeps only its furthest boundary")
    func deduplicatesTierWithFurthestBoundary() {
        let plan = PromptCachePlanner.plan(
            directive([
                breakpoint(.history, index: 2),
                breakpoint(.history, index: 6),
            ]),
            maxBreakpoints: 4
        )

        #expect(plan.breakpoints.count == 1)
        #expect(plan.breakpoints.first?.messageIndex == 6)
    }

    @Test("short retention omits ttl while extended requests the one-hour window")
    func retentionMarkerMapping() {
        #expect(PromptCacheControl.marker(for: .short).ttl == nil)
        #expect(PromptCacheControl.marker(for: .extended).ttl == "1h")
        #expect(PromptCacheControl.marker(for: .extended).type == "ephemeral")
    }

    @Test("Anthropic minimum prefix distinguishes Haiku from other models")
    func anthropicMinimumPrefix() {
        #expect(PromptCacheProviderDefaults.anthropicMinimumPrefixTokens(for: "claude-3-5-haiku") == 2_048)
        #expect(PromptCacheProviderDefaults.anthropicMinimumPrefixTokens(for: "claude-sonnet-4-5") == 1_024)
    }
}
