import Foundation
import PKPrompt
import PKShared
import Testing
@testable import PositronicKit

private func makePromptWorkspace(id: UUID = UUID(), path: String) -> WorkspaceReference {
    WorkspaceReference(
        id: id,
        uri: WorkspaceURI(host: "test-host", path: path),
        location: .attached
    )
}

private struct TimelineSection: Prompt {
    let id: String
    let priority: Int
    let estimatedTokens: Int
    let cachePolicy: CachePolicy
    let compression: CompressionStrategy
    let text: String

    init(
        id: String,
        priority: Int = 0,
        estimatedTokens: Int = 10,
        cachePolicy: CachePolicy,
        compression: CompressionStrategy = .keep,
        text: String
    ) {
        self.id = id
        self.priority = priority
        self.estimatedTokens = estimatedTokens
        self.cachePolicy = cachePolicy
        self.compression = compression
        self.text = text
    }

    var body: some Prompt {
        TextPrompt(
            id: id,
            priority: priority,
            compression: compression,
            cachePolicy: cachePolicy,
            estimatedTokens: estimatedTokens,
            render: { text }
        )
    }
}

@Suite("TimelinePromptHistory")
actor TimelinePromptHistoryTests {
    @Test("Runtime metadata hashing stays aligned between prompt assembly and timeline history")
    func runtimeMetadataHashingStaysAligned() async throws {
        let history = TimelinePromptHistory()
        let rendered = try await PromptAssembler.assemble(LLMPromptRequest(
            userQuery: "Current question",
            contextNotes: [ContextFile(name: "note.md", content: "Context", source: "Notes")],
            memories: [],
            chatHistory: [],
            tools: [],
            workspaces: [makePromptWorkspace(path: "/repo-a")],
            primaryWorkspace: nil,
            requestOriginName: nil
        ))

        let historyMetadata = await history.nodeMetadata(prompt: rendered)

        for section in rendered.sections {
            let content = rendered.sectionsByID[section.id] ?? ""
            let expected = StructuredPromptMetadata.makeNodeMetadata(
                for: section,
                renderedContent: content
            )
            #expect(historyMetadata[section.id] == expected)
        }
    }

    @Test("Metadata hash changes when section traits change even if text stays the same")
    func metadataHashChangesWhenTraitsChange() async throws {
        let promptA = try await AnyPrompt.build {
            TimelineSection(
                id: "system",
                priority: 0,
                estimatedTokens: 10,
                cachePolicy: .stable,
                text: "Same"
            )
        }.assemblePrompt().render()

        let promptB = try await AnyPrompt.build {
            TimelineSection(
                id: "system",
                priority: 10,
                estimatedTokens: 10,
                cachePolicy: .stable,
                text: "Same"
            )
        }.assemblePrompt().render()

        let sectionA = try #require(promptA.sections.first)
        let sectionB = try #require(promptB.sections.first)
        let metadataA = StructuredPromptMetadata.makeNodeMetadata(
            for: sectionA,
            renderedContent: promptA.sectionsByID[sectionA.id] ?? ""
        )
        let metadataB = StructuredPromptMetadata.makeNodeMetadata(
            for: sectionB,
            renderedContent: promptB.sectionsByID[sectionB.id] ?? ""
        )

        #expect(metadataA != metadataB)
        #expect(metadataA.path == metadataB.path)
    }

    @Test("History updates compact appended state when thresholds are exceeded")
    func historyUpdatesCompactWhenThresholdsExceeded() async throws {
        let history = TimelinePromptHistory(thresholds: .init(maxAppendedTokens: 1, maxAppendedMessages: 1))
        let prompt = try AnyPrompt.build {
            TimelineSection(id: "system", cachePolicy: .stable, text: "System")
            TimelineSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assemblePrompt()

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
        }.assemblePrompt()

        let initialDiff = await history.record(prompt: initialPrompt)
        #expect(initialDiff.hasChanges)
        #expect(initialDiff.added.map(\.entryId) == ["system", "context", "query"])
        #expect(initialDiff.stablePrefixCount == 0)

        let updatedPrompt = try AnyPrompt.build {
            TimelineSection(id: "system", cachePolicy: .stable, text: "System")
            TimelineSection(id: "context", cachePolicy: .semiStable, text: "Context v2")
            TimelineSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assemblePrompt()

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
        }.assemblePrompt()

        let initialDiff = await history.record(prompt: prompt)
        let updatedPrompt = try AnyPrompt.build {
            TimelineSection(id: "system", cachePolicy: .stable, text: "A2")
            TimelineSection(id: "query", cachePolicy: .volatile, text: "B")
        }.assemblePrompt()

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

        #expect(await history.shouldCompact == false)
        #expect(await history.appendedMessageCount == 2)
        #expect(await history.appendedTokens > 0)
    }

    @Test("Layer 3 compaction preserves or resets the journal base as requested")
    func layer3CompactionPreservesOrResetsJournalBase() async throws {
        let history = TimelinePromptHistory(thresholds: .init(maxAppendedTokens: 1, maxAppendedMessages: 1))
        let prompt = try AnyPrompt.build {
            TimelineSection(id: "system", cachePolicy: .stable, text: "System")
            TimelineSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assemblePrompt()

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
        let sections = try! AnyPrompt([
            TimelineSection(id: "system", cachePolicy: .stable, text: "A"),
            TimelineSection(id: "query", cachePolicy: .volatile, text: "B"),
        ]).assemblePrompt().sections

        _ = await history.record(sections: sections, renderedContent: ["system": "A", "query": "B"])
        let diff = await history.record(sections: sections, renderedContent: ["system": "A2", "query": "B"])

        #expect(diff.changedNodePaths == [sections[0].path])
        #expect(diff.stableNodePaths == [sections[1].path])
        #expect(diff.addedNodePaths.isEmpty)
        #expect(diff.removedNodePaths.isEmpty)
    }

    @Test("Changing attached workspaces only invalidates the workspaces section")
    func changingWorkspacesOnlyInvalidatesWorkspaceSection() async throws {
        let history = TimelinePromptHistory()

        let requestV1 = LLMPromptRequest(
            userQuery: "Current question",
            chatHistory: [],
            tools: [],
            workspaces: [makePromptWorkspace(path: "/repo-a")],
            primaryWorkspace: nil,
            requestOriginName: nil
        )
        let requestV2 = LLMPromptRequest(
            userQuery: "Current question",
            chatHistory: [],
            tools: [],
            workspaces: [
                makePromptWorkspace(path: "/repo-a"),
                makePromptWorkspace(path: "/repo-b"),
            ],
            primaryWorkspace: nil,
            requestOriginName: nil
        )

        let initialPrompt = try await PromptAssembler.assemble(requestV1)
        _ = await history.record(prompt: initialPrompt)

        let updatedPrompt = try await PromptAssembler.assemble(requestV2)
        let diff = await history.record(prompt: updatedPrompt)

        #expect(diff.changed.map { $0.entryId } == ["workspaces"])
        #expect(diff.added.isEmpty)
        #expect(diff.removed.isEmpty)
    }
}

@Suite("TimelinePromptHistoryRegistry")
actor TimelinePromptHistoryRegistryTests {
    @Test("history(for:) reuses the same instance for the same timeline id")
    func historyReusesSameInstanceForSameTimelineId() async throws {
        let registry = TimelinePromptHistoryRegistry()
        let timelineId = UUID()

        let first = await registry.history(for: timelineId)
        await first.recordAppend(messageCount: 3, estimatedTokens: 42)

        let second = await registry.history(for: timelineId)

        // Same underlying actor: state set via `first` is visible through `second`.
        #expect(await second.appendedMessageCount == 3)
        #expect(await second.appendedTokens == 42)
    }

    @Test("history(for:) isolates state across different timeline ids")
    func historyIsolatesStateAcrossDifferentTimelineIds() async throws {
        let registry = TimelinePromptHistoryRegistry()
        let timelineA = UUID()
        let timelineB = UUID()

        let historyA = await registry.history(for: timelineA)
        await historyA.recordAppend(messageCount: 5, estimatedTokens: 100)

        let historyB = await registry.history(for: timelineB)

        #expect(await historyA.appendedMessageCount == 5)
        #expect(await historyB.appendedMessageCount == 0)
        #expect(await historyB.appendedTokens == 0)
    }

    @Test("removeHistory(for:) followed by history(for:) yields a fresh instance")
    func removeHistoryYieldsFreshInstance() async throws {
        let registry = TimelinePromptHistoryRegistry()
        let timelineId = UUID()

        let original = await registry.history(for: timelineId)
        await original.recordAppend(messageCount: 7, estimatedTokens: 200)
        #expect(await original.appendedMessageCount == 7)

        await registry.removeHistory(for: timelineId)

        let fresh = await registry.history(for: timelineId)

        #expect(await fresh.appendedMessageCount == 0)
        #expect(await fresh.appendedTokens == 0)
        #expect(await fresh.lastDiff == nil)
    }

    @Test("Exceeding the max entry count evicts the least-recently-accessed timeline")
    func exceedingMaxEntriesEvictsLeastRecentlyAccessed() async throws {
        let cap = 5
        let registry = TimelinePromptHistoryRegistry(
            evictionPolicy: RegistryEvictionPolicy(maxEntries: cap)
        )

        var timelineIds: [UUID] = []
        for _ in 0 ..< cap {
            let id = UUID()
            timelineIds.append(id)
            _ = await registry.history(for: id)
        }

        // Refresh the recency of the first (oldest-by-insertion) timeline so it is no longer
        // the least-recently-accessed entry.
        let refreshedId = timelineIds[0]
        let refreshedHistory = await registry.history(for: refreshedId)
        await refreshedHistory.recordAppend(messageCount: 1, estimatedTokens: 1)

        // The second-oldest timeline was never re-accessed, so it's now the true LRU victim.
        let staleId = timelineIds[1]

        // Push past the cap: this should evict `staleId`, not `refreshedId`.
        let newId = UUID()
        _ = await registry.history(for: newId)

        // The refreshed timeline must have survived eviction with its state intact.
        let stillPresent = await registry.history(for: refreshedId)
        #expect(await stillPresent.appendedMessageCount == 1)

        // The stale timeline should have been evicted: asking for it again creates a *fresh*
        // instance (appendedMessageCount reset to 0), proving the old one was dropped.
        let evictedAndRecreated = await registry.history(for: staleId)
        #expect(await evictedAndRecreated.appendedMessageCount == 0)
    }
}
