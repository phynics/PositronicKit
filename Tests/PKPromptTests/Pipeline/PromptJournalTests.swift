import Testing
@testable import PKPrompt
import PKShared
import PKUtilities

@Suite("PromptJournal")
struct PromptJournalTests {
    private func renderPrompt(system: String, context: String, query: String) async -> RenderedPrompt {
        let prompt = try! AnyPrompt.build {
            SystemPrompt(system)
            TextPrompt(context, id: "context", cachePolicy: .semiStable)
            UserPrompt(query)
        }.assemblePrompt()

        return await prompt.render()
    }

    private func renderPrompt(system: String, context: String?, query: String) async -> RenderedPrompt {
        let prompt = try! AnyPrompt.build {
            SystemPrompt(system)
            if let context {
                TextPrompt(context, id: "context", cachePolicy: .semiStable)
            }
            UserPrompt(query)
        }.assemblePrompt()

        return await prompt.render()
    }

    @Test("Initial observation materializes stable and semistable base while volatile stays current")
    func initialObservationBuildsBaseAndVolatileLayers() async {
        var journal = PromptJournal()
        let rendered = await renderPrompt(system: "System v1", context: "Context v1", query: "Question")

        let plan = journal.observe(rendered)

        #expect(plan.requiresHardReset == false)
        #expect(plan.baseSections.map(\.section.id) == ["system", "context"])
        #expect(plan.overlaySections.isEmpty)
        #expect(plan.volatileSections.map(\.section.id) == ["user_query"])
        #expect(plan.baseSections.map(\.layer) == [.base, .base])
        #expect(plan.volatileSections.map(\.layer) == [.volatile])
        #expect(plan.baseSections.map(\.journalPath) == [
            ["prompt", "base", "stable", "system"],
            ["prompt", "base", "semiStable", "context"],
        ])
        #expect(plan.volatileSections.map(\.journalPath) == [["prompt", "volatile", "user_query"]])
    }

    @Test("Semistable changes become overlay without mutating committed base")
    func semistableChangesCreateOverlay() async {
        var journal = PromptJournal()
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        let plan = journal.observe(await renderPrompt(system: "System v1", context: "Context v2", query: "Question"))

        #expect(plan.requiresHardReset == false)
        #expect(plan.baseSections.map(\.section.id) == ["system", "context"])
        #expect(plan.baseSections[1].renderedText == "Context v1")
        #expect(plan.overlaySections.map(\.section.id) == ["context"])
        #expect(plan.overlaySections[0].renderedText == "Context v2")
        #expect(plan.overlaySections[0].layer == .overlay)
        #expect(plan.overlaySections[0].journalPath == ["prompt", "overlay", "semiStable", "context"])
        #expect(plan.volatileSections.map(\.section.id) == ["user_query"])
    }

    @Test("Compaction promotes latest semistable state into base and clears overlay")
    func compactionPromotesOverlayIntoBase() async {
        var journal = PromptJournal()
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v2", query: "Question"))

        let compacted = journal.compact()

        #expect(compacted != nil)
        #expect(compacted?.overlaySections.isEmpty == true)
        #expect(compacted?.baseSections.map(\.section.id) == ["system", "context"])
        #expect(compacted?.baseSections[1].renderedText == "Context v2")
        #expect(compacted?.volatileSections.map(\.section.id) == ["user_query"])
    }

    @Test("Append pressure auto-compacts the latest accepted observation before the next diff")
    func appendPressureAutoCompactsLatestObservation() async {
        var journal = PromptJournal(thresholds: .init(maxAppendedTokens: 1, maxAppendedMessages: 1))
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v2", query: "Question"))

        journal.recordAppend(messages: [
            Message(content: "Assistant reply", role: .assistant),
            Message(content: "Tool output", role: .tool),
        ])

        #expect(journal.shouldCompact)

        let plan = journal.observe(await renderPrompt(system: "System v1", context: "Context v2", query: "Question"))

        #expect(!journal.shouldCompact)
        #expect(plan.requiresHardReset == false)
        #expect(plan.baseSections.map(\.section.id) == ["system", "context"])
        #expect(plan.baseSections[1].renderedText == "Context v2")
        #expect(plan.overlaySections.isEmpty)
        #expect(plan.diff.hasOverlayChanges == false)
    }

    @Test("Volatile changes never enter the committed base")
    func volatileChangesStayOutOfBase() async {
        var journal = PromptJournal()
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question 1"))

        let plan = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question 2"))

        #expect(plan.baseSections.map(\.section.id) == ["system", "context"])
        #expect(plan.overlaySections.isEmpty)
        #expect(plan.volatileSections.map(\.section.id) == ["user_query"])
        #expect(plan.volatileSections[0].renderedText == "Question 2")
    }

    @Test("Stable changes require hard reset")
    func stableChangesRequireHardReset() async {
        var journal = PromptJournal()
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        let plan = journal.observe(await renderPrompt(system: "System v2", context: "Context v1", query: "Question"))

        #expect(plan.requiresHardReset)
        #expect(plan.overlaySections.isEmpty)
        #expect(plan.baseSections.map(\.section.id) == ["system", "context"])
        #expect(plan.baseSections[0].renderedText == "System v2")
    }

    @Test("Initial observation emits a snapshot message set")
    func initialObservationBuildsSnapshotMessages() async {
        var journal = PromptJournal()
        let plan = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        #expect(plan.emissionMode == .snapshot)

        let messages = plan.buildMessages()
        #expect(messages.count == 4)
        #expect(messages[0].role == .system)
        #expect(messages[1].content.contains("<prompt_journal_snapshot"))
        #expect(messages[1].content.contains("id=\"system\""))
        #expect(messages[2].content.contains("<prompt_journal_snapshot"))
        #expect(messages[2].content.contains("id=\"context\""))
        #expect(messages[3].role == .user)
        #expect(messages[3].content == "Question")
    }

    @Test("Semistable changes emit delta update messages")
    func semistableChangesBuildDeltaMessages() async {
        var journal = PromptJournal()
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        let plan = journal.observe(await renderPrompt(system: "System v1", context: "Context v2", query: "Question"))

        #expect(plan.emissionMode == .delta)

        let messages = plan.buildMessages()
        #expect(messages.count == 2)
        #expect(messages[0].role == .system)
        #expect(messages[0].content.contains("<prompt_journal_replace"))
        #expect(messages[0].content.contains("id=\"context\""))
        #expect(messages[0].content.contains("Context v2"))
        #expect(messages[1].role == .user)
        #expect(messages[1].content == "Question")
    }

    @Test("Semistable removals emit remove update messages")
    func semistableRemovalBuildsRemoveMessage() async {
        var journal = PromptJournal()
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        let plan = journal.observe(await renderPrompt(system: "System v1", context: nil, query: "Question"))

        #expect(plan.emissionMode == .delta)
        #expect(plan.diff.removedSemiStableIDs == ["context"])

        let messages = plan.buildMessages()
        #expect(messages.count == 2)
        #expect(messages[0].content.contains("<prompt_journal_remove"))
        #expect(messages[0].content.contains("id=\"context\""))
        #expect(messages[1].role == .user)
    }

    @Test("Manual compact clears append pressure")
    func manualCompactClearsAppendPressure() async {
        var journal = PromptJournal(thresholds: .init(maxAppendedTokens: 1, maxAppendedMessages: 1))
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        journal.recordAppend(messages: [
            Message(content: "Assistant reply", role: .assistant),
            Message(content: "Tool output", role: .tool),
        ])
        #expect(journal.shouldCompact)

        _ = journal.compact()

        #expect(!journal.shouldCompact)
    }
}

private extension JournaledPromptSection {
    var renderedText: String? {
        section.content.text
    }
}
