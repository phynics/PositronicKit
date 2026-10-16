import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

/// End-to-end coverage for #280: per-round prompt-cache reports flow through the event stream,
/// persist on the Turn, and are readable as a value snapshot through the Timeline handle.
@Suite("Prompt cache runtime reports", .serialized, .timeLimit(.minutes(2)), .tags(.integration))
struct PromptCacheRuntimeTests {
    private func usageChunk(_ text: String) -> LLMStreamChunk {
        LLMStreamChunk(
            id: "chunk",
            model: "mock",
            choices: [
                LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(role: .assistant, content: text),
                    finishReason: "stop"
                ),
            ],
            usage: LLMTokenUsage(
                promptTokens: 100,
                completionTokens: 5,
                totalTokens: 105,
                promptTokensDetails: LLMTokenUsagePromptDetails(
                    cachedTokens: 80,
                    cacheWriteTokens: 20
                )
            )
        )
    }

    @Test("reports track the prefix across two Turns and promptState exposes the layout")
    func reportsAndPromptState() async throws {
        let llm = MockLLMService()
        let kit = TestRuntime(workspaceRoot: TestRuntime.uniqueWorkspaceRoot(), llm: llm).runtime
        let timeline = try await kit.timelines.create(title: "Prompt Cache Reports")
        let agent = try await kit.agents.create(name: "Cache Report Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let driver = kit.timelines.open(timeline.id)

        llm.mockClient.nextRawStreamChunks = [[usageChunk("one")]]
        let first = try await driver.startTurn("first question")
        for await event in first.events() {
            #expect(event.promptCacheReport == nil || event.promptCacheReport?.turnID == first.id)
        }
        let firstReports = try await first.promptCacheReports()
        #expect(firstReports.count == 1)
        #expect(firstReports.first?.resets == [.firstRound])
        #expect(firstReports.first?.reportedCachedTokens == 80)
        #expect(firstReports.first?.reportedCacheWriteTokens == 20)
        #expect(firstReports.first?.expectedReusableTokens == 0)

        llm.mockClient.nextRawStreamChunks = [[usageChunk("two")]]
        let second = try await driver.startTurn("second question")
        for await _ in second.events() {}
        let secondReports = try await second.promptCacheReports()
        #expect(secondReports.count == 1)
        #expect(secondReports.first?.resets.isEmpty == true)
        #expect((secondReports.first?.expectedReusableTokens ?? 0) > 0)
        #expect(secondReports.first?.reportedCachedTokens == 80)

        let state = await driver.promptState()
        #expect(state.turnID == second.id)
        #expect(state.modelRoundIndex == 1)
        #expect(!state.segments.isEmpty)
        #expect(state.tiers.count == PromptCacheTier.allCases.count)
        #expect(!state.breakpoints.isEmpty)
        #expect(state.resets.isEmpty)
    }
}
