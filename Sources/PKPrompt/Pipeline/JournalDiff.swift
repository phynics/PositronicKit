import Foundation

// MARK: - JournalDiff

public struct JournalDiff<Entry: PipelineSnapshotEntry>: Sendable {
    public struct SubtreeDiff: Sendable {
        public let changedNodePaths: [[String]]
        public let stableNodePaths: [[String]]
        public let addedNodePaths: [[String]]
        public let removedNodePaths: [[String]]

        public init(
            changedNodePaths: [[String]],
            stableNodePaths: [[String]],
            addedNodePaths: [[String]],
            removedNodePaths: [[String]]
        ) {
            self.changedNodePaths = changedNodePaths
            self.stableNodePaths = stableNodePaths
            self.addedNodePaths = addedNodePaths
            self.removedNodePaths = removedNodePaths
        }
    }

    /// Entries unchanged from the start (same position, same ID, same hash).
    public let stablePrefixCount: Int
    /// Entries with same ID but different hash.
    public let changed: [Entry]
    /// Entries not in previous snapshot.
    public let added: [Entry]
    /// Entry IDs removed since previous snapshot.
    public let removed: [String]
    /// Optional tree-aware diff payload when hierarchy metadata is available.
    public let subtreeDiff: SubtreeDiff?

    public var hasChanges: Bool {
        !changed.isEmpty || !added.isEmpty || !removed.isEmpty || hasSubtreeChanges
    }

    private var hasSubtreeChanges: Bool {
        guard let subtreeDiff else { return false }
        return !subtreeDiff.changedNodePaths.isEmpty
            || !subtreeDiff.addedNodePaths.isEmpty
            || !subtreeDiff.removedNodePaths.isEmpty
    }

    public static func initial(entries: [Entry]) -> JournalDiff<Entry> {
        JournalDiff(stablePrefixCount: 0, changed: [], added: entries, removed: [], subtreeDiff: nil)
    }
}
