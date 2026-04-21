import PKPrompt
import PKShared
import Testing
@testable import PositronicKit

private struct TimelineSection: PromptLeaf {
    let id: String
    let priority: Int
    let estimatedTokens: Int
    let cachePolicy: CachePolicy
    let compression: CompressionStrategy
    let type: PromptSectionType
    let text: String

    init(
        id: String,
        priority: Int = 0,
        estimatedTokens: Int = 10,
        cachePolicy: CachePolicy,
        compression: CompressionStrategy = .keep,
        type: PromptSectionType = .text,
        text: String
    ) {
        self.id = id
        self.priority = priority
        self.estimatedTokens = estimatedTokens
        self.cachePolicy = cachePolicy
        self.compression = compression
        self.type = type
        self.text = text
    }

    func renderContent() async -> String? {
        text
    }
}

@Suite("TimelinePromptHistory")
actor TimelinePromptHistoryTests {
    @Test("History updates compact appended state when thresholds are exceeded")
    func historyUpdatesCompactWhenThresholdsExceeded() async throws {
        let history = TimelinePromptHistory(thresholds: .init(maxAppendedTokens: 1, maxAppendedMessages: 1))
        let prompt = try AnyPrompt.build {
            TimelineSection(id: "system", cachePolicy: .stable, text: "System")
            TimelineSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assembledPrompt()

        let initialUpdate = await history.update(prompt: prompt)
        #expect(initialUpdate.diff?.added.map(\.entryId) == ["system", "query"])
        #expect(initialUpdate.didCompact == false)

        let appendUpdate = await history.append(messages: [
            Message(content: "Assistant reply", role: .assistant),
            Message(content: "Tool output", role: .tool),
        ])

        #expect(appendUpdate.didCompact)
        #expect(appendUpdate.diff == nil)
        #expect(await history.appendedMessageCount == 0)
        #expect(await history.appendedTokens == 0)
        #expect(!(await history.shouldCompact))

        let nextUpdate = await history.update(prompt: prompt)
        #expect(nextUpdate.didCompact == false)
        #expect(nextUpdate.diff?.hasChanges == false)
        #expect(nextUpdate.diff?.stablePrefixCount == prompt.sections.count)
    }

    @Test("Layer 3 journals prompt evolution across turns")
    func layer3JournalsPromptEvolutionAcrossTurns() async throws {
        let history = TimelinePromptHistory()

        let initialPrompt = try AnyPrompt.build {
            TimelineSection(id: "system", cachePolicy: .stable, text: "System")
            TimelineSection(id: "context", cachePolicy: .semiStable, text: "Context v1")
            TimelineSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assembledPrompt()

        let initialDiff = await history.record(prompt: initialPrompt)

        #expect(initialDiff.hasChanges)
        #expect(initialDiff.added.map(\.entryId) == ["system", "context", "query"])
        #expect(initialDiff.stablePrefixCount == 0)

        let updatedPrompt = try AnyPrompt.build {
            TimelineSection(id: "system", cachePolicy: .stable, text: "System")
            TimelineSection(id: "context", cachePolicy: .semiStable, text: "Context v2")
            TimelineSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assembledPrompt()

        let diff = await history.record(prompt: updatedPrompt)

        #expect(diff.stablePrefixCount == 1)
        #expect(diff.stablePrefixTokens == updatedPrompt.sections[0].estimatedTokens)
        #expect(diff.changed.map(\.entryId) == ["context"])
        #expect(diff.changedNodePaths == [updatedPrompt.sections[1].path])
        #expect(diff.stableNodePaths == [updatedPrompt.sections[0].path, updatedPrompt.sections[2].path])
    }

    @Test("Records an assembled prompt directly")
    func recordsAssembledPromptDirectly() async throws {
        let history = TimelinePromptHistory()
        let prompt = try AnyPrompt.build {
            TimelineSection(id: "system", cachePolicy: .stable, text: "A")
            TimelineSection(id: "query", cachePolicy: .volatile, text: "B")
        }.assembledPrompt()

        let initialDiff = await history.record(prompt: prompt)
        let updatedPrompt = try AnyPrompt.build {
            TimelineSection(id: "system", cachePolicy: .stable, text: "A2")
            TimelineSection(id: "query", cachePolicy: .volatile, text: "B")
        }.assembledPrompt()

        let diff = await history.record(prompt: updatedPrompt)

        #expect(initialDiff.added.map(\.entryId) == ["system", "query"])
        #expect(diff.changed.map(\.entryId) == ["system"])
        #expect(diff.stableNodePaths == [updatedPrompt.sections[1].path])
    }

    @Test("Tracks appended messages directly")
    func tracksAppendedMessages() async {
        let history = TimelinePromptHistory()
        let messages = [
            Message(content: "Tool output", role: .tool),
            Message(content: "Assistant follow-up", role: .assistant),
        ]

        await history.recordAppend(messages: messages)

        let shouldCompact = await history.shouldCompact
        #expect(shouldCompact == false)
        #expect(await history.appendedMessageCount == 2)
        #expect(await history.appendedTokens > 0)
    }

    @Test("Layer 3 compaction preserves or resets the journal base as requested")
    func layer3CompactionPreservesOrResetsJournalBase() async throws {
        let history = TimelinePromptHistory(thresholds: .init(maxAppendedTokens: 1, maxAppendedMessages: 1))
        let prompt = try AnyPrompt.build {
            TimelineSection(id: "system", cachePolicy: .stable, text: "System")
            TimelineSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assembledPrompt()

        _ = await history.record(prompt: prompt)
        await history.recordAppend(messages: [
            Message(content: "Assistant reply", role: .assistant),
            Message(content: "Tool output", role: .tool),
        ])

        #expect(await history.shouldCompact)

        await history.compact()

        #expect(await history.appendedMessageCount == 0)
        #expect(await history.appendedTokens == 0)
        #expect(!(await history.shouldCompact))

        let softDiff = await history.record(prompt: prompt)
        #expect(!softDiff.hasChanges)
        #expect(softDiff.stablePrefixCount == prompt.sections.count)

        await history.compact(hard: true)

        let hardDiff = await history.record(prompt: prompt)
        #expect(hardDiff.added.map(\.entryId) == ["system", "query"])
        #expect(hardDiff.stablePrefixCount == 0)
    }

    @Test("Exposes subtree diff node-path stats")
    func exposesSubtreeDiffStats() async {
        let history = TimelinePromptHistory()
        let sections = [
            TimelineSection(id: "system", cachePolicy: .stable, text: "A"),
            TimelineSection(id: "query", cachePolicy: .volatile, text: "B"),
        ].flatMap { $0.resolveSections(in: PromptResolutionContext()) }

        _ = await history.record(sections: sections, renderedContent: ["system": "A", "query": "B"])
        let diff = await history.record(sections: sections, renderedContent: ["system": "A2", "query": "B"])

        #expect(diff.changedNodePaths == [sections[0].path])
        #expect(diff.stableNodePaths == [sections[1].path])
        #expect(diff.addedNodePaths.isEmpty)
        #expect(diff.removedNodePaths.isEmpty)
    }
}
