import Testing
@testable import PKPrompt

private struct JournalEntry: PipelineSnapshotEntry {
    let entryId: String
    let content: String
    let path: [String]
    let parentEntryId: String?
    let order: Int?
    let sectionKind: PipelineSnapshotSectionKind?
}

private struct JournalSnapshot: PipelineSnapshot {
    let entries: [JournalEntry]
}

@Suite("PipelineJournal tree diff")
struct PipelineJournalTreeDiffTests {
    @Test("Computes subtree-level changes when hierarchy metadata exists")
    func computesTreeDiff() {
        var journal = PipelineJournal<JournalSnapshot>()

        _ = journal.record(.init(entries: [
            .init(entryId: "system", content: "A", path: ["prompt", "stable", "system"], parentEntryId: nil, order: 0, sectionKind: .section),
            .init(entryId: "history", content: "B", path: ["prompt", "volatile", "history"], parentEntryId: nil, order: 1, sectionKind: .section),
        ]))

        let diff = journal.record(.init(entries: [
            .init(entryId: "system", content: "A2", path: ["prompt", "stable", "system"], parentEntryId: nil, order: 0, sectionKind: .section),
            .init(entryId: "query", content: "C", path: ["prompt", "volatile", "query"], parentEntryId: nil, order: 2, sectionKind: .section),
        ]))

        #expect(diff.subtreeDiff != nil)
        #expect(diff.subtreeDiff?.changedNodePaths == [["prompt", "stable", "system"]])
        #expect(diff.subtreeDiff?.stableNodePaths == [])
        #expect(diff.subtreeDiff?.addedNodePaths == [["prompt", "volatile", "query"]])
        #expect(diff.subtreeDiff?.removedNodePaths == [["prompt", "volatile", "history"]])
    }

    @Test("Falls back to flat diff when hierarchy metadata is absent")
    func fallsBackToFlatDiff() {
        var journal = PipelineJournal<JournalSnapshot>()
        _ = journal.record(.init(entries: [
            .init(entryId: "one", content: "A", path: ["one"], parentEntryId: nil, order: nil, sectionKind: nil),
        ]))

        let diff = journal.record(.init(entries: [
            .init(entryId: "one", content: "B", path: ["one"], parentEntryId: nil, order: nil, sectionKind: nil),
        ]))

        #expect(diff.changed.count == 1)
        #expect(diff.subtreeDiff == nil)
    }
}
