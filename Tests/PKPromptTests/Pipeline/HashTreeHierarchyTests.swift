import Testing
@testable import PKPrompt

private struct HierarchyEntry: PipelineSnapshotEntry {
    let entryId: String
    let content: String
    let path: [String]
    let parentEntryId: String?
    let order: Int?
    let sectionKind: PipelineSnapshotSectionKind?
}

@Suite("HashTree hierarchy")
struct HashTreeHierarchyTests {
    @Test("Builds semantic hierarchy from metadata")
    func buildsSemanticHierarchy() {
        let entries: [HierarchyEntry] = [
            .init(entryId: "system", content: "A", path: ["prompt", "stable", "system"], parentEntryId: nil, order: 0, sectionKind: .section),
            .init(entryId: "tools", content: "B", path: ["prompt", "semiStable", "tools"], parentEntryId: nil, order: 1, sectionKind: .section),
            .init(entryId: "query", content: "C", path: ["prompt", "volatile", "query"], parentEntryId: nil, order: 2, sectionKind: .section),
        ]

        let tree = HashTree(entries: entries)

        #expect(tree.semanticRoots.count == 1)
        #expect(tree.semanticRoots.first?.path == ["prompt"])
        #expect(tree.semanticRoots.first?.children.count == 3)
        #expect(tree.semanticRoots.first?.children.map(\.path.last) == ["stable", "semiStable", "volatile"])
    }

    @Test("Preserves associative state hash semantics")
    func preservesStateHash() {
        let entries: [HierarchyEntry] = [
            .init(entryId: "one", content: "one", path: ["root", "one"], parentEntryId: nil, order: 0, sectionKind: .section),
            .init(entryId: "two", content: "two", path: ["root", "two"], parentEntryId: nil, order: 1, sectionKind: .section),
        ]

        let tree = HashTree(entries: entries)
        let expected = entries.reduce(UInt64.zero) { $0 &+ $1.contentHash }
        #expect(tree.stateHash == expected)
    }
}
