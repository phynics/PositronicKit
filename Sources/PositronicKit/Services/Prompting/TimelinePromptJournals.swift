import Foundation
import PKPrompt

// MARK: - TimelinePromptJournals

/// Holds one `TimelinePromptHistory` per timeline, so prompt-cache and
/// journal-diff state (the stable-prefix count, changed/added/removed semi-stable IDs)
/// accumulates across a timeline's sends rather than resetting on every call.
actor TimelinePromptJournals {
    private var historiesByTimelineID: [UUID: TimelinePromptHistory] = [:]
    /// Timeline ids ordered from least- to most-recently accessed. The front of the array is
    /// the next eviction candidate. Kept as a plain array (not a generic LRU abstraction) --
    /// this registry isn't a hot path and entry counts are bounded by `evictionPolicy.maxEntries`.
    private var accessOrder: [UUID] = []
    private let thresholds: PromptJournalCompactionThresholds
    private let evictionPolicy: RegistryEvictionPolicy

    init(
        thresholds: PromptJournalCompactionThresholds = .default,
        evictionPolicy: RegistryEvictionPolicy = .default
    ) {
        self.thresholds = thresholds
        self.evictionPolicy = evictionPolicy
    }

    /// Returns the existing history for `timelineID`, creating one on first use.
    /// Every call refreshes `timelineID`'s recency for LRU eviction purposes.
    func history(for timelineID: UUID) -> TimelinePromptHistory {
        if let existing = historiesByTimelineID[timelineID] {
            touch(timelineID)
            return existing
        }
        evictIfNeeded()
        let created = TimelinePromptHistory(thresholds: thresholds)
        historiesByTimelineID[timelineID] = created
        touch(timelineID)
        return created
    }

    /// Package-only inspection used by runtime ordering tests. Unlike `history(for:)`, this does
    /// not create a journal entry as a side effect.
    package func containsHistory(for timelineID: UUID) -> Bool {
        historiesByTimelineID[timelineID] != nil
    }

    /// Drops the cached history for a timeline, e.g. when a timeline is deleted.
    func removeHistory(for timelineID: UUID) {
        historiesByTimelineID.removeValue(forKey: timelineID)
        accessOrder.removeAll { $0 == timelineID }
    }

    /// Moves `timelineID` to the most-recently-accessed end of `accessOrder`.
    private func touch(_ timelineID: UUID) {
        accessOrder.removeAll { $0 == timelineID }
        accessOrder.append(timelineID)
    }

    /// Evicts the least-recently-accessed entry if the registry is at capacity.
    private func evictIfNeeded() {
        guard historiesByTimelineID.count >= evictionPolicy.maxEntries,
              let oldest = accessOrder.first else { return }
        historiesByTimelineID.removeValue(forKey: oldest)
        accessOrder.removeFirst()
    }
}
