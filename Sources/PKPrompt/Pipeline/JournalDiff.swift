import Foundation

// MARK: - JournalDiff

public struct JournalDiff<Entry: PipelineSnapshotEntry>: Sendable {
    /// Entries unchanged from the start (same position, same ID, same hash).
    public let stablePrefixCount: Int
    /// Entries with same ID but different hash.
    public let changed: [Entry]
    /// Entries not in previous snapshot.
    public let added: [Entry]
    /// Entry IDs removed since previous snapshot.
    public let removed: [String]

    public var hasChanges: Bool {
        !changed.isEmpty || !added.isEmpty || !removed.isEmpty
    }

    public static func initial(entries: [Entry]) -> JournalDiff<Entry> {
        JournalDiff(stablePrefixCount: 0, changed: [], added: entries, removed: [])
    }
}
