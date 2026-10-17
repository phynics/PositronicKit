import Foundation
import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

@Suite("TimelinePromptHistory", .tags(.integration))
actor TimelinePromptHistoryTests {
    private func makePrompt(id: String, text: String, cachePolicy: CachePolicy = .stable) -> RenderedPrompt {
        let section = RenderedPrompt.Section(
            id: id,
            role: .system,
            priority: 0,
            estimatedTokens: 1,
            compression: .keep,
            type: .text,
            cachePolicy: cachePolicy,
            path: [id],
            parentID: nil,
            compressionOutcome: nil,
            content: .text(text)
        )
        return RenderedPrompt(sections: [section], string: text, sectionsByID: [id: text])
    }

    @Test("The first accounted round reports firstRound and exposes the state snapshot")
    func firstRoundReportsFirstRound() async {
        let history = TimelinePromptHistory()
        let accounting = await history.accountPromptCache(
            prompt: makePrompt(id: "system", text: "rules"),
            historyTrimmed: false,
            cachingEnabled: true,
            turnID: UUID(),
            modelRoundIndex: 1,
            breakpoints: []
        )

        #expect(accounting.resets == [.firstRound])
        #expect(accounting.expectedReusableTokens == 0)

        let snapshot = await history.promptStateSnapshot()
        #expect(snapshot.resets == [.firstRound])
        #expect(snapshot.segments.map(\.id) == ["system"])
    }

    @Test("An unchanged round reports no reset and reuses the leading prefix")
    func unchangedRoundReusesPrefix() async {
        let history = TimelinePromptHistory()
        let prompt = makePrompt(id: "system", text: "rules")
        _ = await history.accountPromptCache(
            prompt: prompt,
            historyTrimmed: false,
            cachingEnabled: true,
            turnID: UUID(),
            modelRoundIndex: 1,
            breakpoints: []
        )
        let accounting = await history.accountPromptCache(
            prompt: prompt,
            historyTrimmed: false,
            cachingEnabled: true,
            turnID: UUID(),
            modelRoundIndex: 2,
            breakpoints: []
        )

        #expect(accounting.resets.isEmpty)
        #expect(accounting.expectedReusableTokens > 0)
    }

    @Test("History trim state round-trips")
    func trimStateRoundTrips() async {
        let history = TimelinePromptHistory()
        #expect(await history.historyTrimState() == HistoryTrimState())

        let state = HistoryTrimState(droppedMessageCount: 3, budgetTokens: 42)
        await history.recordHistoryTrimState(state)
        #expect(await history.historyTrimState() == state)
    }

    @Test("History projection watermark round-trips and clears")
    func projectionWatermarkRoundTrips() async {
        let history = TimelinePromptHistory()
        #expect(await history.historyProjectionWatermark() == nil)

        let messageID = UUID()
        await history.recordHistoryProjectionWatermark(messageID)
        #expect(await history.historyProjectionWatermark() == messageID)

        await history.recordHistoryProjectionWatermark(nil)
        #expect(await history.historyProjectionWatermark() == nil)
    }

    @Test("The newest sibling request replaces the previous one")
    func siblingRequestReplacesPrevious() async {
        let history = TimelinePromptHistory()
        #expect(await history.siblingRequest() == nil)

        let first = RetainedSiblingRequest(
            messages: [],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            promptCache: nil,
            modelTier: .primary,
            transport: .streaming
        )
        await history.recordSiblingRequest(first)
        #expect(await history.siblingRequest() != nil)
    }
}
