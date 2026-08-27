import Foundation
@testable import PKContracts
@testable import PKPrompt
import PKUtilities
import Testing

/// Prompt journal and rendering coverage.
@Suite("Prompt journal and rendering coverage")
struct PKPromptJournalCoverageTests {
    @Test("Resetting the observation preserves the committed base")
    func resetSoftClearsObservation() throws {
        let journal = try PromptJournalHelper.makeJournalWithBase()
        var j = journal.journal
        _ = try j.observe(journal.rendered)

        j.resetKeepingCommittedState()
        // Should not crash; state reflects cleared observation.
        let state = j.state
        #expect(state.latestObservedSections.isEmpty)
        // Committed base is preserved.
        #expect(!state.committedBaseSections.isEmpty)
    }

    @Test("Resetting all journal state clears the committed base")
    func resetHardClearsEverything() throws {
        let journal = try PromptJournalHelper.makeJournalWithBase()
        var j = journal.journal
        _ = try j.observe(journal.rendered)

        j.resetDiscardingCommittedState()
        let state = j.state
        #expect(state.latestObservedSections.isEmpty)
        #expect(state.committedBaseSections.isEmpty)
    }

    @Test("compact() returns nil when nothing has been observed")
    func compactReturnsNilWhenEmpty() {
        var j = PromptJournal()
        let plan = j.compact()
        #expect(plan == nil)
    }

    // MARK: - PromptJournalPlan+Messages rendering

    @Test("buildMessages renders snapshot mode with preamble and section tags")
    func buildMessagesSnapshotMode() {
        let plan = PromptJournalMessageHelper.makeSnapshotPlan()
        let messages = plan.buildMessages()

        #expect(messages.count >= 1)
        #expect(messages.first?.isSummary == true)
        #expect(messages.first?.content.contains("PromptJournal") == true)
    }

    @Test("buildMessages renders delta mode with replace/add/remove tags")
    func buildMessagesDeltaMode() {
        let plan = PromptJournalMessageHelper.makeDeltaPlan()
        let messages = plan.buildMessages()

        // Should contain replacement and removal messages.
        #expect(!messages.isEmpty)
        let hasRemove = messages.contains { $0.content.contains("prompt_journal_remove") }
        #expect(hasRemove)
    }

    @Test("buildMessages includes volatile chat history messages")
    func buildMessagesVolatileHistory() {
        let plan = PromptJournalMessageHelper.makePlanWithVolatileHistory()
        let messages = plan.buildMessages()

        // Should contain the history messages.
        #expect(messages.contains { $0.role == .user })
    }

    @Test("buildMessages includes volatile user query")
    func buildMessagesVolatileUserQuery() {
        let plan = PromptJournalMessageHelper.makePlanWithVolatileUserQuery()
        let messages = plan.buildMessages()

        #expect(messages.contains { $0.content == "What is 2+2?" })
    }

    @Test("buildMessages includes volatile system content")
    func buildMessagesVolatileSystem() {
        let plan = PromptJournalMessageHelper.makePlanWithVolatileSystem()
        let messages = plan.buildMessages()

        #expect(messages.contains { $0.role == .system && $0.content.contains("System instructions") })
    }

    @Test("formatHistoryMessage formats assistant with reasoning")
    func formatHistoryMessageWithReasoning() {
        let plan = PromptJournalMessageHelper.makeDeltaPlanWithReasoning()
        let messages = plan.buildMessages()
        // The assistant reasoning should be included in the output.
        #expect(messages.contains { $0.content.contains("Let me think") })
    }

    // MARK: - AssembledPrompt formatting

    @Test("AssembledPrompt.render formats assistant messages with reasoning tags")
    func assembledPromptRendersReasoning() async throws {
        let section = PromptSectionHelper.makeTextSection(
            content: .messages([
                Message(content: "answer", role: .assistant, reasoning: "because"),
            ]),
            role: .chatHistory
        )
        let prompt = try? await AssembledPrompt(sections: [section]).render()
        let rendered = try #require(prompt)
        #expect(rendered.string.contains("because"))
        #expect(rendered.string.contains("answer"))
    }

    @Test("AssembledPrompt.render formats tool and summary messages")
    func assembledPromptRendersToolAndSummary() async throws {
        let section = PromptSectionHelper.makeTextSection(
            content: .messages([
                Message(content: "tool output", role: .tool),
                Message(content: "summary text", role: .summary, isSummary: true),
            ]),
            role: .chatHistory
        )
        let prompt = try? await AssembledPrompt(sections: [section]).render()
        let rendered = try #require(prompt)
        #expect(rendered.string.contains("tool output"))
        #expect(rendered.string.contains("summary text"))
    }

    @Test("AssembledPrompt.render skips empty message arrays")
    func assembledPromptSkipsEmptyMessages() async throws {
        let section = PromptSectionHelper.makeTextSection(
            content: .messages([]),
            role: .chatHistory
        )
        let prompt = try? await AssembledPrompt(sections: [section]).render()
        let rendered = try #require(prompt)
        // Empty messages should produce no string content.
        #expect(rendered.string.isEmpty)
    }

    // MARK: - SectionCompressor default implementation

    @Test("buildMessages formats all history message roles in delta mode")
    func buildMessagesAllHistoryRoles() {
        let messages: [Message] = [
            Message(content: "hi", role: .user),
            Message(content: "ok", role: .assistant),
            Message(content: "sys", role: .system),
            Message(content: "tool output", role: .tool),
            Message(content: "summary text", role: .summary, isSummary: true),
        ]
        let section = JournaledPromptSection(
            section: RenderedPrompt.Section(
                id: "hist", role: .chatHistory, priority: 50, estimatedTokens: 10,
                compression: .keep, type: .text, cachePolicy: .semiStable,
                path: ["root", "hist"], parentID: nil,
                content: .messages(messages)
            ),
            layer: .overlay, sourcePath: ["root", "hist"], journalPath: ["root", "hist"]
        )
        let plan = PromptJournalPlan(
            baseSections: [], overlaySections: [section], volatileSections: [],
            requiresHardReset: false,
            diff: PromptJournalDiff(addedSemiStableIDs: ["hist"]),
            emissionMode: .delta
        )
        let result = plan.buildMessages()
        let combined = result.map(\.content).joined()
        #expect(combined.contains("User: hi"))
        #expect(combined.contains("Assistant: ok"))
        #expect(combined.contains("System: sys"))
        #expect(combined.contains("Tool: tool output"))
        #expect(combined.contains("Summary: summary text"))
    }

    @Test("buildMessages skips empty text in snapshot mode")
    func buildMessagesSkipsEmptyTextSnapshot() {
        let section = JournaledPromptSection(
            section: RenderedPrompt.Section(
                id: "empty", role: .context, priority: 50, estimatedTokens: 10,
                compression: .keep, type: .text, cachePolicy: .stable,
                path: ["root", "empty"], parentID: nil,
                content: .text("")
            ),
            layer: .base, sourcePath: ["root", "empty"], journalPath: ["root", "empty"]
        )
        let plan = PromptJournalPlan(
            baseSections: [section], overlaySections: [], volatileSections: [],
            requiresHardReset: false, diff: PromptJournalDiff(), emissionMode: .snapshot
        )
        let messages = plan.buildMessages()
        // The empty section should be skipped (only the preamble remains).
        #expect(messages.count == 1)
        #expect(messages.first?.isSummary == true)
    }

    @Test("buildMessages skips empty messages array in delta mode")
    func buildMessagesSkipsEmptyMessagesDelta() {
        let section = JournaledPromptSection(
            section: RenderedPrompt.Section(
                id: "empty", role: .chatHistory, priority: 50, estimatedTokens: 10,
                compression: .keep, type: .text, cachePolicy: .semiStable,
                path: ["root", "empty"], parentID: nil,
                content: .messages([])
            ),
            layer: .overlay, sourcePath: ["root", "empty"], journalPath: ["root", "empty"]
        )
        let plan = PromptJournalPlan(
            baseSections: [], overlaySections: [section], volatileSections: [],
            requiresHardReset: false,
            diff: PromptJournalDiff(addedSemiStableIDs: ["empty"]),
            emissionMode: .delta
        )
        let messages = plan.buildMessages()
        // The empty section should be skipped.
        #expect(messages.isEmpty)
    }
}

// MARK: - Final gap coverage

// MARK: - Final gap coverage

extension PKPromptJournalCoverageTests {
    @Test("PromptJournalDiffer detects added semistable sections")
    func differDetectsAddedSections() throws {
        let baseSection = RenderedPrompt.Section(
            id: "base", role: .context, priority: 50, estimatedTokens: 10,
            compression: .keep, type: .text, cachePolicy: .stable,
            path: ["root", "base"], parentID: nil, content: .text("base")
        )
        let newSection = RenderedPrompt.Section(
            id: "new", role: .context, priority: 50, estimatedTokens: 10,
            compression: .keep, type: .text, cachePolicy: .semiStable,
            path: ["root", "new"], parentID: nil, content: .text("new")
        )
        let evaluation = try PromptJournalDiffer.evaluate(
            committedBaseSections: [baseSection],
            currentSections: [baseSection, newSection]
        )
        #expect(evaluation.diff.addedSemiStableIDs.contains("new"))
    }

    @Test("EmptyMutable buildMessages includes volatile multimodal user query content")
    func buildMessagesMultimodalUserQuery() {
        let content = MessageContent(parts: [
            .text("Look at this"),
            .image(ImageContent(data: Data([1]), mediaType: "image/png")),
        ])
        let section = JournaledPromptSection(
            section: RenderedPrompt.Section(
                id: "query", role: .userQuery, priority: 90, estimatedTokens: 10,
                compression: .keep, type: .text, cachePolicy: .volatile,
                path: ["root", "query"], parentID: nil, content: .multimodal(content)
            ),
            layer: .volatile, sourcePath: ["root", "query"], journalPath: ["root", "query"]
        )
        let plan = PromptJournalPlan(
            baseSections: [], overlaySections: [], volatileSections: [section],
            requiresHardReset: false, diff: PromptJournalDiff(), emissionMode: .snapshot
        )
        let messages = plan.buildMessages()
        #expect(messages.contains { $0.role == .user && $0.content.contains("Look at this") })
    }

    @Test("Snapshot journal text falls back to the multimodal text projection")
    func snapshotMultimodalJournalText() {
        let content = MessageContent(parts: [
            .text("tagged content"),
            .audio(AudioContent(data: Data([2]), format: .mp3)),
        ])
        let section = JournaledPromptSection(
            section: RenderedPrompt.Section(
                id: "mm", role: .context, priority: 50, estimatedTokens: 10,
                compression: .keep, type: .text, cachePolicy: .stable,
                path: ["root", "mm"], parentID: nil, content: .multimodal(content)
            ),
            layer: .base, sourcePath: ["root", "mm"], journalPath: ["root", "mm"]
        )
        let plan = PromptJournalPlan(
            baseSections: [section], overlaySections: [], volatileSections: [],
            requiresHardReset: false, diff: PromptJournalDiff(), emissionMode: .snapshot
        )
        let messages = plan.buildMessages()
        #expect(messages.contains { $0.content.contains("tagged content") })
    }
}
