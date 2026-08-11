import Foundation
import Testing
@testable import PKPrompt
import PKShared
import PKUtilities

@Suite("PromptJournal")
struct PromptJournalTests {
    private func stateSection(
        id: String,
        content: PromptSection.Content,
        cachePolicy: CachePolicy = .semiStable
    ) -> RenderedPrompt.Section {
        RenderedPrompt.Section(
            id: id,
            role: .chatHistory,
            priority: 75,
            estimatedTokens: 12,
            compression: .truncate(keeping: .tail),
            type: .list,
            cachePolicy: cachePolicy,
            path: ["prompt", "history", id],
            parentID: "history",
            compressionOutcome: CompressionNodeReport(
                nodeID: id,
                path: ["prompt", "history", id],
                action: .truncate(limit: 12, keeping: .tail),
                beforeTokens: 24,
                afterTokens: 12,
                cacheHit: true,
                fallbackReason: "budget"
            ),
            content: content
        )
    }

    private func duplicatePrompt(cachePolicy: CachePolicy) -> RenderedPrompt {
        let sections = [
            stateSection(id: "duplicate", content: .text("first"), cachePolicy: cachePolicy),
            stateSection(id: "duplicate", content: .text("second"), cachePolicy: cachePolicy),
        ]
        return RenderedPrompt(
            sections: sections,
            string: "first\nsecond",
            sectionsByID: [:]
        )
    }

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
    func initialObservationBuildsBaseAndVolatileLayers() async throws {
        var journal = PromptJournal()
        let rendered = await renderPrompt(system: "System v1", context: "Context v1", query: "Question")

        let plan = try journal.observe(rendered)

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
    func semistableChangesCreateOverlay() async throws {
        var journal = PromptJournal()
        _ = try journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        let plan = try journal.observe(await renderPrompt(system: "System v1", context: "Context v2", query: "Question"))

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
    func compactionPromotesOverlayIntoBase() async throws {
        var journal = PromptJournal()
        _ = try journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))
        _ = try journal.observe(await renderPrompt(system: "System v1", context: "Context v2", query: "Question"))

        let compacted = journal.compact()

        #expect(compacted != nil)
        #expect(compacted?.overlaySections.isEmpty == true)
        #expect(compacted?.baseSections.map(\.section.id) == ["system", "context"])
        #expect(compacted?.baseSections[1].renderedText == "Context v2")
        #expect(compacted?.volatileSections.map(\.section.id) == ["user_query"])
    }

    @Test("Append pressure auto-compacts the latest accepted observation before the next diff")
    func appendPressureAutoCompactsLatestObservation() async throws {
        var journal = PromptJournal(thresholds: .init(maxAppendedTokens: 1, maxAppendedMessages: 1))
        _ = try journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))
        _ = try journal.observe(await renderPrompt(system: "System v1", context: "Context v2", query: "Question"))

        journal.recordAppend(messages: [
            Message(content: "Assistant reply", role: .assistant),
            Message(content: "Tool output", role: .tool),
        ])

        #expect(journal.shouldCompact)

        let plan = try journal.observe(await renderPrompt(system: "System v1", context: "Context v2", query: "Question"))

        #expect(!journal.shouldCompact)
        #expect(plan.requiresHardReset == false)
        #expect(plan.baseSections.map(\.section.id) == ["system", "context"])
        #expect(plan.baseSections[1].renderedText == "Context v2")
        #expect(plan.overlaySections.isEmpty)
        #expect(plan.diff.hasOverlayChanges == false)
    }

    @Test("Volatile changes never enter the committed base")
    func volatileChangesStayOutOfBase() async throws {
        var journal = PromptJournal()
        _ = try journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question 1"))

        let plan = try journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question 2"))

        #expect(plan.baseSections.map(\.section.id) == ["system", "context"])
        #expect(plan.overlaySections.isEmpty)
        #expect(plan.volatileSections.map(\.section.id) == ["user_query"])
        #expect(plan.volatileSections[0].renderedText == "Question 2")
    }

    @Test("Stable changes require hard reset")
    func stableChangesRequireHardReset() async throws {
        var journal = PromptJournal()
        _ = try journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        let plan = try journal.observe(await renderPrompt(system: "System v2", context: "Context v1", query: "Question"))

        #expect(plan.requiresHardReset)
        #expect(plan.overlaySections.isEmpty)
        #expect(plan.baseSections.map(\.section.id) == ["system", "context"])
        #expect(plan.baseSections[0].renderedText == "System v2")
    }

    @Test("Initial observation emits a snapshot message set")
    func initialObservationBuildsSnapshotMessages() async throws {
        var journal = PromptJournal()
        let plan = try journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

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
    func semistableChangesBuildDeltaMessages() async throws {
        var journal = PromptJournal()
        _ = try journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        let plan = try journal.observe(await renderPrompt(system: "System v1", context: "Context v2", query: "Question"))

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
    func semistableRemovalBuildsRemoveMessage() async throws {
        var journal = PromptJournal()
        _ = try journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        let plan = try journal.observe(await renderPrompt(system: "System v1", context: nil, query: "Question"))

        #expect(plan.emissionMode == .delta)
        #expect(plan.diff.removedSemiStableIDs == ["context"])

        let messages = plan.buildMessages()
        #expect(messages.count == 2)
        #expect(messages[0].content.contains("<prompt_journal_remove"))
        #expect(messages[0].content.contains("id=\"context\""))
        #expect(messages[1].role == .user)
    }

    @Test("Manual compact clears append pressure")
    func manualCompactClearsAppendPressure() async throws {
        var journal = PromptJournal(thresholds: .init(maxAppendedTokens: 1, maxAppendedMessages: 1))
        _ = try journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        journal.recordAppend(messages: [
            Message(content: "Assistant reply", role: .assistant),
            Message(content: "Tool output", role: .tool),
        ])
        #expect(journal.shouldCompact)

        _ = journal.compact()

        #expect(!journal.shouldCompact)
    }

    @Test("Prompt journal state round-trips every hydration field")
    func stateRoundTripPreservesSectionsMetadataContentAndPressure() throws {
        var journal = PromptJournal(thresholds: .init(maxAppendedTokens: 17, maxAppendedMessages: 3))
        let base = stateSection(id: "base", content: .text("base content"))
        let latest = stateSection(
            id: "latest",
            content: .messages([Message(content: "assistant", role: .assistant)])
        )
        journal = PromptJournal(state: .init(
            committedBaseSections: [base],
            latestObservedSections: [base, latest],
            appendedMessageCount: 2,
            appendedTokens: 19,
            thresholds: .init(maxAppendedTokens: 17, maxAppendedMessages: 3)
        ))

        let data = try JSONEncoder().encode(journal.state)
        let decoded = try JSONDecoder().decode(PromptJournal.State.self, from: data)

        #expect(decoded == journal.state)
        #expect(decoded.committedBaseSections == [base])
        #expect(decoded.latestObservedSections == [base, latest])
        #expect(decoded.appendedMessageCount == 2)
        #expect(decoded.appendedTokens == 19)
        #expect(decoded.thresholds == .init(maxAppendedTokens: 17, maxAppendedMessages: 3))
    }

    @Test("Duplicate stable IDs are rejected before the first observation mutates state")
    func duplicateStableIDsAreRejectedOnFirstObservation() {
        var journal = PromptJournal()
        let stateBefore = journal.state

        #expect(throws: PromptJournal.ValidationError.duplicateStableSectionIDs(["duplicate"])) {
            try journal.observe(duplicatePrompt(cachePolicy: .stable))
        }
        #expect(journal.state == stateBefore)
    }

    @Test("Duplicate stable IDs are rejected without mutating a subsequent observation")
    func duplicateStableIDsAreRejectedOnSubsequentObservation() async throws {
        var journal = PromptJournal()
        _ = try journal.observe(await renderPrompt(system: "System", context: "Context", query: "Question"))
        let stateBefore = journal.state

        #expect(throws: PromptJournal.ValidationError.duplicateStableSectionIDs(["duplicate"])) {
            try journal.observe(duplicatePrompt(cachePolicy: .stable))
        }
        #expect(journal.state == stateBefore)
    }

    @Test("Duplicate semi-stable IDs are rejected before the first observation mutates state")
    func duplicateSemiStableIDsAreRejectedOnFirstObservation() {
        var journal = PromptJournal()
        let stateBefore = journal.state

        #expect(throws: PromptJournal.ValidationError.duplicateSemiStableSectionIDs(["duplicate"])) {
            try journal.observe(duplicatePrompt(cachePolicy: .semiStable))
        }
        #expect(journal.state == stateBefore)
    }

    @Test("Duplicate semi-stable IDs are rejected without mutating a subsequent observation")
    func duplicateSemiStableIDsAreRejectedOnSubsequentObservation() async throws {
        var journal = PromptJournal()
        _ = try journal.observe(await renderPrompt(system: "System", context: "Context", query: "Question"))
        let stateBefore = journal.state

        #expect(throws: PromptJournal.ValidationError.duplicateSemiStableSectionIDs(["duplicate"])) {
            try journal.observe(duplicatePrompt(cachePolicy: .semiStable))
        }
        #expect(journal.state == stateBefore)
    }

    @Test("Hydrated journal observes the same plan as the live journal")
    func hydratedObservationMatchesLiveObservation() async throws {
        var live = PromptJournal(thresholds: .init(maxAppendedTokens: 1, maxAppendedMessages: 1))
        _ = try live.observe(await renderPrompt(system: "System", context: "Context v1", query: "Question 1"))
        _ = try live.observe(await renderPrompt(system: "System", context: "Context v2", query: "Question 2"))
        live.recordAppend(messageCount: 2, estimatedTokens: 3)

        var hydrated = PromptJournal(state: try JSONDecoder().decode(
            PromptJournal.State.self,
            from: JSONEncoder().encode(live.state)
        ))
        let next = await renderPrompt(system: "System", context: "Context v3", query: "Question 3")

        let livePlan = try live.observe(next)
        let hydratedPlan = try hydrated.observe(next)

        #expect(livePlan.baseSections.map(\.section) == hydratedPlan.baseSections.map(\.section))
        #expect(livePlan.overlaySections.map(\.section) == hydratedPlan.overlaySections.map(\.section))
        #expect(livePlan.volatileSections.map(\.section) == hydratedPlan.volatileSections.map(\.section))
        #expect(livePlan.requiresHardReset == hydratedPlan.requiresHardReset)
        #expect(livePlan.diff == hydratedPlan.diff)
        #expect(livePlan.emissionMode == hydratedPlan.emissionMode)
        #expect(livePlan.buildMessages().map(\.content) == hydratedPlan.buildMessages().map(\.content))
        #expect(livePlan.buildMessages().map(\.role) == hydratedPlan.buildMessages().map(\.role))
        #expect(live.state == hydrated.state)
    }
}

private extension JournaledPromptSection {
    var renderedText: String? {
        section.content.text
    }
}
