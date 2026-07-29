import Foundation
import PKPrompt

// MARK: - TimelinePromptJournals

/// Holds one `TimelinePromptHistory` per conversation timeline, so prompt-cache and
/// journal-diff state (the stable-prefix count, changed/added/removed semi-stable IDs)
/// accumulates across a conversation's sends rather than resetting on every call.
actor TimelinePromptJournals {
    private var historiesByTimelineId: [UUID: TimelinePromptHistory] = [:]
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

    /// Returns the existing history for `timelineId`, creating one on first use.
    /// Every call refreshes `timelineId`'s recency for LRU eviction purposes.
    func history(for timelineId: UUID) -> TimelinePromptHistory {
        if let existing = historiesByTimelineId[timelineId] {
            touch(timelineId)
            return existing
        }
        evictIfNeeded()
        let created = TimelinePromptHistory(thresholds: thresholds)
        historiesByTimelineId[timelineId] = created
        touch(timelineId)
        return created
    }

    /// Drops the cached history for a timeline, e.g. when a conversation is deleted.
    func removeHistory(for timelineId: UUID) {
        historiesByTimelineId.removeValue(forKey: timelineId)
        accessOrder.removeAll { $0 == timelineId }
    }

    /// Moves `timelineId` to the most-recently-accessed end of `accessOrder`.
    private func touch(_ timelineId: UUID) {
        accessOrder.removeAll { $0 == timelineId }
        accessOrder.append(timelineId)
    }

    /// Evicts the least-recently-accessed entry if the registry is at capacity.
    private func evictIfNeeded() {
        guard historiesByTimelineId.count >= evictionPolicy.maxEntries,
              let oldest = accessOrder.first else { return }
        historiesByTimelineId.removeValue(forKey: oldest)
        accessOrder.removeFirst()
    }
}
