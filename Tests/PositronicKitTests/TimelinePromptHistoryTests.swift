import Foundation
import PKPrompt
import PKShared
import PKUtilities
@testable import PositronicKit
import Testing

private func makePromptWorkspace(id: UUID = UUID(), path: String) -> WorkspaceReference {
    WorkspaceReference(
        id: id,
        uri: WorkspaceURI(host: "test-host", path: path),
        location: .attached
    )
}

private struct ThreadSection: Prompt {
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

@Suite("ThreadPromptHistory")
actor ThreadPromptHistoryTests {
    @Test("Runtime metadata hashing stays aligned between prompt assembly and thread history")
    func runtimeMetadataHashingStaysAligned() async throws {
        let history = ThreadPromptHistory()
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
            let expected = section.nodeMetadata(renderedContent: content)
            #expect(historyMetadata[section.id] == expected)
        }
    }

    @Test("Duplicate journal sections fail the transition with a typed error")
    func duplicateJournalSectionsAreRecoverable() async throws {
        let history = ThreadPromptHistory()
        let prompt = try await PromptAssembler.assemble(LLMPromptRequest(
            userQuery: "question",
            contextNotes: [],
            memories: [],
            chatHistory: [],
            tools: [],
            workspaces: [],
            primaryWorkspace: nil,
            requestOriginName: nil
        ))
        let rendered = prompt
        let duplicate = RenderedPrompt(
            sections: [rendered.sections[0], rendered.sections[0]],
            string: rendered.string,
            sectionsByID: rendered.sectionsByID
        )

        do {
            _ = try await history.record(prompt: duplicate)
            Issue.record("Duplicate journal section was accepted")
        } catch let error as ThreadPromptHistoryError {
            #expect(error == .duplicateSectionIDs([rendered.sections[0].id]))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Journal transitions remain valid across repeated append and compact cycles")
    func journalTransitionPropertyLoop() async throws {
        let history = ThreadPromptHistory(thresholds: .init(maxAppendedTokens: 20, maxAppendedMessages: 2))

        for index in 0 ..< 32 {
            let section = try AnyPrompt.build {
                TextPrompt("context-\(index)", id: "context", cachePolicy: .semiStable)
                UserPrompt("question-\(index)")
            }.assemblePrompt()
            _ = try await history.record(prompt: section)
            await history.recordAppend(messageCount: 1, estimatedTokens: 8)
            if await history.shouldCompact {
                await history.compact()
            }
        }

        #expect(await history.lastDiff != nil)
    }

    @Test("History updates compact appended state when thresholds are exceeded")
    func historyUpdatesCompactWhenThresholdsExceeded() async throws {
        let history = ThreadPromptHistory(thresholds: .init(maxAppendedTokens: 1, maxAppendedMessages: 1))
        let prompt = try AnyPrompt.build {
            ThreadSection(id: "system", cachePolicy: .stable, text: "System")
            ThreadSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assemblePrompt()

        let initialUpdate = try! await history.update(prompt: prompt)
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

        let nextUpdate = try! await history.update(prompt: prompt)
        #expect(nextUpdate.didCompact == false)
        #expect(nextUpdate.diff?.hasChanges == false)
        #expect(nextUpdate.diff?.stablePrefixCount == prompt.sections.count)
    }

    @Test("Layer 3 journals prompt evolution across turns")
    func layer3JournalsPromptEvolutionAcrossTurns() async throws {
        let history = ThreadPromptHistory()

        let initialPrompt = try AnyPrompt.build {
            ThreadSection(id: "system", cachePolicy: .stable, text: "System")
            ThreadSection(id: "context", cachePolicy: .semiStable, text: "Context v1")
            ThreadSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assemblePrompt()

        let initialDiff = try! await history.record(prompt: initialPrompt)
        #expect(initialDiff.hasChanges)
        #expect(initialDiff.added.map(\.entryId) == ["system", "context", "query"])
        #expect(initialDiff.stablePrefixCount == 0)

        let updatedPrompt = try AnyPrompt.build {
            ThreadSection(id: "system", cachePolicy: .stable, text: "System")
            ThreadSection(id: "context", cachePolicy: .semiStable, text: "Context v2")
            ThreadSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assemblePrompt()

        let diff = try! await history.record(prompt: updatedPrompt)

        #expect(diff.stablePrefixCount == 1)
        #expect(diff.stablePrefixTokens == updatedPrompt.sections[0].estimatedTokens)
        #expect(diff.changed.map(\.entryId) == ["context"])
        #expect(diff.changedNodePaths == [updatedPrompt.sections[1].path])
        #expect(diff.stableNodePaths == [updatedPrompt.sections[0].path, updatedPrompt.sections[2].path])
    }

    @Test("PromptJournal and runtime history share semistable diff IDs while runtime also tracks cache prefix")
    func promptJournalAndRuntimeHistoryShareSemistableDiffIDs() async throws {
        var journal = PromptJournal()
        let history = ThreadPromptHistory()

        let initialPrompt = try AnyPrompt.build {
            ThreadSection(id: "system", cachePolicy: .stable, text: "System")
            ThreadSection(id: "context", cachePolicy: .semiStable, text: "Context v1")
            ThreadSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assemblePrompt()
        let initialRendered = await initialPrompt.render()

        _ = try journal.observe(initialRendered)
        _ = try! await history.record(prompt: initialPrompt)

        let updatedPrompt = try AnyPrompt.build {
            ThreadSection(id: "system", cachePolicy: .stable, text: "System")
            ThreadSection(id: "context", cachePolicy: .semiStable, text: "Context v2")
            ThreadSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assemblePrompt()
        let updatedRendered = await updatedPrompt.render()

        let journalPlan = try journal.observe(updatedRendered)
        let runtimeDiff = try! await history.record(prompt: updatedPrompt)

        #expect(journalPlan.requiresHardReset == false)
        #expect(journalPlan.diff == runtimeDiff.publicJournalDiff)
        #expect(runtimeDiff.stablePrefixCount == 1)

        // Mixed-policy churn: stable stays unchanged, but volatile and semiStable
        // sections change. The runtime journal projection must agree with PKPrompt by
        // emitting only semistable IDs; stable/volatile IDs must not leak through.
        var mixedJournal = PromptJournal()
        let mixedHistory = ThreadPromptHistory()

        let mixedInitial = try AnyPrompt.build {
            ThreadSection(id: "stable-a", cachePolicy: .stable, text: "Stable A")
            ThreadSection(id: "semi-a", cachePolicy: .semiStable, text: "Semi A v1")
            ThreadSection(id: "volatile-a", cachePolicy: .volatile, text: "Volatile A v1")
        }.assemblePrompt()
        let mixedInitialRendered = await mixedInitial.render()

        _ = try mixedJournal.observe(mixedInitialRendered)
        _ = try! await mixedHistory.record(prompt: mixedInitial)

        let mixedUpdated = try AnyPrompt.build {
            ThreadSection(id: "stable-a", cachePolicy: .stable, text: "Stable A")
            ThreadSection(id: "semi-a", cachePolicy: .semiStable, text: "Semi A v2")
            ThreadSection(id: "semi-b", cachePolicy: .semiStable, text: "Semi B new")
            ThreadSection(id: "volatile-a", cachePolicy: .volatile, text: "Volatile A v2")
        }.assemblePrompt()
        let mixedUpdatedRendered = await mixedUpdated.render()

        let mixedJournalPlan = try mixedJournal.observe(mixedUpdatedRendered)
        let mixedRuntimeDiff = try! await mixedHistory.record(prompt: mixedUpdated)

        #expect(mixedJournalPlan.requiresHardReset == false)
        #expect(mixedJournalPlan.diff == mixedRuntimeDiff.publicJournalDiff)
        #expect(mixedRuntimeDiff.publicJournalDiff == PromptJournalDiff(
            changedSemiStableIDs: ["semi-a"],
            addedSemiStableIDs: ["semi-b"],
            removedSemiStableIDs: []
        ))
        #expect(mixedRuntimeDiff.stablePrefixCount == 1)
    }

    @Test("publicJournalDiff emits only semistable IDs when stable and volatile sections change")
    func publicJournalDiffFiltersNonSemistableChanges() async throws {
        let history = ThreadPromptHistory()

        let initialPrompt = try AnyPrompt.build {
            ThreadSection(id: "stable-a", cachePolicy: .stable, text: "Stable A v1")
            ThreadSection(id: "semi-a", cachePolicy: .semiStable, text: "Semi A v1")
            ThreadSection(id: "volatile-a", cachePolicy: .volatile, text: "Volatile A v1")
        }.assemblePrompt()

        let updatedPrompt = try AnyPrompt.build {
            ThreadSection(id: "stable-a", cachePolicy: .stable, text: "Stable A v2")
            ThreadSection(id: "semi-a", cachePolicy: .semiStable, text: "Semi A v2")
            ThreadSection(id: "semi-b", cachePolicy: .semiStable, text: "Semi B new")
            ThreadSection(id: "volatile-a", cachePolicy: .volatile, text: "Volatile A v2")
        }.assemblePrompt()

        _ = try! await history.record(prompt: initialPrompt)
        let diff = try! await history.record(prompt: updatedPrompt)

        // Runtime diff must continue to track all policies for the cache prefix / subtree.
        #expect(diff.changed.map(\.entryId) == ["stable-a", "semi-a", "volatile-a"])
        #expect(diff.added.map(\.entryId) == ["semi-b"])
        #expect(diff.removed.isEmpty)

        // Public projection is semistable-only.
        #expect(diff.publicJournalDiff == PromptJournalDiff(
            changedSemiStableIDs: ["semi-a"],
            addedSemiStableIDs: ["semi-b"],
            removedSemiStableIDs: []
        ))
    }

    @Test("Token-only changes do not register as diffs under the unified text-only fingerprint")
    func tokenOnlyChangesDoNotRegisterAsDiff() async throws {
        var journal = PromptJournal()
        let history = ThreadPromptHistory()

        let initialPrompt = try AnyPrompt.build {
            ThreadSection(id: "semi-token", estimatedTokens: 10, cachePolicy: .semiStable, text: "Same text")
        }.assemblePrompt()
        let initialRendered = await initialPrompt.render()

        _ = try journal.observe(initialRendered)
        _ = try! await history.record(prompt: initialPrompt)

        // Same text, different estimatedTokens — must NOT diff under the unified text-only scheme.
        let updatedPrompt = try AnyPrompt.build {
            ThreadSection(id: "semi-token", estimatedTokens: 999, cachePolicy: .semiStable, text: "Same text")
        }.assemblePrompt()
        let updatedRendered = await updatedPrompt.render()

        let journalPlan = try journal.observe(updatedRendered)
        let runtimeDiff = try! await history.record(prompt: updatedPrompt)

        #expect(journalPlan.diff == PromptJournalDiff())
        #expect(runtimeDiff.publicJournalDiff == PromptJournalDiff())
        #expect(runtimeDiff.hasChanges == false)
        #expect(runtimeDiff.stablePrefixCount == 1)
    }

    @Test("publicJournalDiff emits only semistable IDs when sections are removed")
    func publicJournalDiffFiltersNonSemistableRemovals() async throws {
        let history = ThreadPromptHistory()

        let initialPrompt = try AnyPrompt.build {
            ThreadSection(id: "stable-a", cachePolicy: .stable, text: "Stable A")
            ThreadSection(id: "semi-a", cachePolicy: .semiStable, text: "Semi A")
        }.assemblePrompt()

        let updatedPrompt = try AnyPrompt.build {
            ThreadSection(id: "stable-b", cachePolicy: .stable, text: "Stable B")
            ThreadSection(id: "semi-b", cachePolicy: .semiStable, text: "Semi B")
        }.assemblePrompt()

        _ = try! await history.record(prompt: initialPrompt)
        let diff = try! await history.record(prompt: updatedPrompt)

        // Runtime diff records removals for all policies.
        #expect(diff.removed == ["stable-a", "semi-a"])

        // Public projection drops the stable removal.
        #expect(diff.publicJournalDiff == PromptJournalDiff(
            changedSemiStableIDs: [],
            addedSemiStableIDs: ["semi-b"],
            removedSemiStableIDs: ["semi-a"]
        ))
    }

    @Test("Records an assembled prompt directly")
    func recordsAssembledPromptDirectly() async throws {
        let history = ThreadPromptHistory()
        let prompt = try AnyPrompt.build {
            ThreadSection(id: "system", cachePolicy: .stable, text: "A")
            ThreadSection(id: "query", cachePolicy: .volatile, text: "B")
        }.assemblePrompt()

        let initialDiff = try! await history.record(prompt: prompt)
        let updatedPrompt = try AnyPrompt.build {
            ThreadSection(id: "system", cachePolicy: .stable, text: "A2")
            ThreadSection(id: "query", cachePolicy: .volatile, text: "B")
        }.assemblePrompt()

        let diff = try! await history.record(prompt: updatedPrompt)

        #expect(initialDiff.added.map(\.entryId) == ["system", "query"])
        #expect(diff.changed.map(\.entryId) == ["system"])
        #expect(diff.stableNodePaths == [updatedPrompt.sections[1].path])
    }

    @Test("Tracks appended messages directly")
    func tracksAppendedMessages() async {
        let history = ThreadPromptHistory()
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
        let history = ThreadPromptHistory(thresholds: .init(maxAppendedTokens: 1, maxAppendedMessages: 1))
        let prompt = try AnyPrompt.build {
            ThreadSection(id: "system", cachePolicy: .stable, text: "System")
            ThreadSection(id: "query", cachePolicy: .volatile, text: "Question")
        }.assemblePrompt()

        _ = try! await history.record(prompt: prompt)
        await history.recordAppend(messages: [
            Message(content: "Assistant reply", role: .assistant),
            Message(content: "Tool output", role: .tool),
        ])

        #expect(await history.shouldCompact)

        await history.compact()

        #expect(await history.appendedMessageCount == 0)
        #expect(await history.appendedTokens == 0)
        #expect(!(await history.shouldCompact))

        let softDiff = try! await history.record(prompt: prompt)
        #expect(!softDiff.hasChanges)
        #expect(softDiff.stablePrefixCount == prompt.sections.count)

        await history.compact(hard: true)

        let hardDiff = try! await history.record(prompt: prompt)
        #expect(hardDiff.added.map(\.entryId) == ["system", "query"])
        #expect(hardDiff.stablePrefixCount == 0)
    }

    @Test("Exposes subtree diff node-path stats")
    func exposesSubtreeDiffStats() async throws {
        let history = ThreadPromptHistory()
        let sections = try AnyPrompt([
            ThreadSection(id: "system", cachePolicy: .stable, text: "A"),
            ThreadSection(id: "query", cachePolicy: .volatile, text: "B"),
        ]).assemblePrompt().sections

        _ = try! await history.record(sections: sections, renderedContent: ["system": "A", "query": "B"])
        let diff = try! await history.record(sections: sections, renderedContent: ["system": "A2", "query": "B"])

        #expect(diff.changedNodePaths == [sections[0].path])
        #expect(diff.stableNodePaths == [sections[1].path])
        #expect(diff.addedNodePaths.isEmpty)
        #expect(diff.removedNodePaths.isEmpty)
    }

    @Test("Changing attached workspaces only invalidates the workspaces section")
    func changingWorkspacesOnlyInvalidatesWorkspaceSection() async throws {
        let history = ThreadPromptHistory()

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
        _ = try! await history.record(prompt: initialPrompt)

        let updatedPrompt = try await PromptAssembler.assemble(requestV2)
        let diff = try! await history.record(prompt: updatedPrompt)

        #expect(diff.changed.map { $0.entryId } == ["workspaces"])
        #expect(diff.added.isEmpty)
        #expect(diff.removed.isEmpty)
    }
}

@Suite("ThreadPromptJournals")
actor ThreadPromptJournalsTests {
    @Test("history(for:) reuses the same instance for the same thread ID")
    func historyReusesSameInstanceForSameThreadId() async {
        let registry = ThreadPromptJournals()
        let threadID = UUID()

        let first = await registry.history(for: threadID)
        await first.recordAppend(messageCount: 3, estimatedTokens: 42)

        let second = await registry.history(for: threadID)

        // Same underlying actor: state set via `first` is visible through `second`.
        #expect(await second.appendedMessageCount == 3)
        #expect(await second.appendedTokens == 42)
    }

    @Test("history(for:) isolates state across different thread IDs")
    func historyIsolatesStateAcrossDifferentThreadIds() async {
        let registry = ThreadPromptJournals()
        let threadA = UUID()
        let threadB = UUID()

        let historyA = await registry.history(for: threadA)
        await historyA.recordAppend(messageCount: 5, estimatedTokens: 100)

        let historyB = await registry.history(for: threadB)

        #expect(await historyA.appendedMessageCount == 5)
        #expect(await historyB.appendedMessageCount == 0)
        #expect(await historyB.appendedTokens == 0)
    }

    @Test("removeHistory(for:) followed by history(for:) yields a fresh instance")
    func removeHistoryYieldsFreshInstance() async {
        let registry = ThreadPromptJournals()
        let threadID = UUID()

        let original = await registry.history(for: threadID)
        await original.recordAppend(messageCount: 7, estimatedTokens: 200)
        #expect(await original.appendedMessageCount == 7)

        await registry.removeHistory(for: threadID)

        let fresh = await registry.history(for: threadID)

        #expect(await fresh.appendedMessageCount == 0)
        #expect(await fresh.appendedTokens == 0)
        #expect(await fresh.lastDiff == nil)
    }

    @Test("Exceeding the max entry count evicts the least-recently-accessed thread")
    func exceedingMaxEntriesEvictsLeastRecentlyAccessed() async {
        let cap = 5
        let registry = ThreadPromptJournals(
            evictionPolicy: RegistryEvictionPolicy(maxEntries: cap)
        )

        var threadIds: [UUID] = []
        var historiesById: [UUID: ThreadPromptHistory] = [:]
        for _ in 0 ..< cap {
            let id = UUID()
            threadIds.append(id)
            historiesById[id] = await registry.history(for: id)
        }

        // Mark the second-oldest thread with distinguishing state via its *already-captured*
        // actor reference, never going back through `registry.history(for:)` for it again until
        // the final check below — `history(for:)` itself refreshes recency on every call (hit
        // or miss), so re-fetching through the registry here would accidentally un-stale it.
        // If eviction never fires (or evicts the wrong entry), re-fetching this id through the
        // registry after the cap-exceeding push would still report this marker value instead of
        // the fresh-instance default, so the final assertion can't pass by coincidence the way a
        // bare "== 0" check against never-touched state could (trivially true both when the
        // entry was correctly evicted-and-recreated AND when eviction silently never fired).
        let staleId = threadIds[1]
        await historiesById[staleId]?.recordAppend(messageCount: 99, estimatedTokens: 99)

        // Refresh the recency of the first (oldest-by-insertion) thread, through the registry,
        // so it is no longer the least-recently-accessed entry (this call's own `touch()` is
        // exactly the kind of registry access `staleId` above deliberately avoided).
        let refreshedId = threadIds[0]
        let refreshedHistory = await registry.history(for: refreshedId)
        await refreshedHistory.recordAppend(messageCount: 1, estimatedTokens: 1)

        // Push past the cap: this should evict `staleId`, not `refreshedId`.
        let newId = UUID()
        _ = await registry.history(for: newId)

        // The refreshed thread must have survived eviction with its state intact.
        let stillPresent = await registry.history(for: refreshedId)
        #expect(await stillPresent.appendedMessageCount == 1)

        // The stale thread should have been evicted: asking for it again creates a *fresh*
        // instance (appendedMessageCount reset to 0, not the 99 marker), proving the old one
        // with its marker state was actually dropped rather than merely never having been
        // touched.
        let evictedAndRecreated = await registry.history(for: staleId)
        #expect(await evictedAndRecreated.appendedMessageCount == 0)
    }
}
