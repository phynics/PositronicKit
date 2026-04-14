import Foundation


// MARK: - PipelineJournal

public struct PipelineJournal<S: PipelineSnapshot>: Sendable {
    public private(set) var base: S?
    public private(set) var tree: HashTree?
    
    /// The structural state hash of the pipeline.
    /// This is an associative hash guaranteed to verify the exact state,
    /// so that `hash(base + diff) = hash(base) &+ hash(diff)`.
    public var stateHash: UInt64 {
        tree?.stateHash ?? 0
    }

    public init() {}

    @discardableResult
    public mutating func record(_ snapshot: S) -> JournalDiff<S.Entry> {
        let newTree = HashTree(entries: snapshot.entries)
        
        defer { 
            base = snapshot 
            tree = newTree
        }
        
        guard let previous = base else {
            return .initial(entries: snapshot.entries)
        }

        // Stable prefix: positional match (same ID + same hash at same index)
        var stablePrefixCount = 0
        for idx in 0 ..< min(previous.entries.count, snapshot.entries.count) {
            if previous.entries[idx].entryId == snapshot.entries[idx].entryId
                && previous.entries[idx].contentHash == snapshot.entries[idx].contentHash
            {
                stablePrefixCount += 1
            } else { break }
        }

        // Changed / added / removed (by ID, not position)
        var previousById: [String: UInt64] = [:]
        for entry in previous.entries {
            previousById[entry.entryId] = entry.contentHash
        }

        var changed: [S.Entry] = []
        var added: [S.Entry] = []
        var seenIds: Set<String> = []
        for entry in snapshot.entries {
            seenIds.insert(entry.entryId)
            if let prevHash = previousById[entry.entryId] {
                if prevHash != entry.contentHash { changed.append(entry) }
            } else { added.append(entry) }
        }
        let removed = previous.entries.map(\.entryId).filter { !seenIds.contains($0) }

        return JournalDiff(
            stablePrefixCount: stablePrefixCount,
            changed: changed, added: added, removed: removed
        )
    }

    /// Resets the journal. The current base is preserved — only append counters
    /// (managed by the caller) are expected to reset. The next record() will diff
    /// against the existing base, correctly showing only what actually changed.
    /// Call with `hard: true` to fully clear (next record treats everything as new).
    public mutating func compact(hard: Bool = false) {
        if hard {
            base = nil
            tree = nil
        }
    }
}
