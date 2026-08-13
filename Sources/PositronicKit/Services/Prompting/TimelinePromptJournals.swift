import Foundation
import PKPrompt

// MARK: - ThreadPromptJournals

/// Holds one `ThreadPromptHistory` per conversation thread, so prompt-cache and
/// journal-diff state (the stable-prefix count, changed/added/removed semi-stable IDs)
/// accumulates across a conversation's sends rather than resetting on every call.
public actor ThreadPromptJournals {
    private var historiesByThreadID: [UUID: ThreadPromptHistory] = [:]
    /// Thread ids ordered from least- to most-recently accessed. The front of the array is
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

    /// Returns the existing history for `threadID`, creating one on first use.
    /// Every call refreshes `threadID`'s recency for LRU eviction purposes.
    func history(for threadID: UUID) -> ThreadPromptHistory {
        if let existing = historiesByThreadID[threadID] {
            touch(threadID)
            return existing
        }
        evictIfNeeded()
        let created = ThreadPromptHistory(thresholds: thresholds)
        historiesByThreadID[threadID] = created
        touch(threadID)
        return created
    }

    /// Drops the cached history for a thread, e.g. when a conversation is deleted.
    func removeHistory(for threadID: UUID) {
        historiesByThreadID.removeValue(forKey: threadID)
        accessOrder.removeAll { $0 == threadID }
    }

    /// Moves `threadID` to the most-recently-accessed end of `accessOrder`.
    private func touch(_ threadID: UUID) {
        accessOrder.removeAll { $0 == threadID }
        accessOrder.append(threadID)
    }

    /// Evicts the least-recently-accessed entry if the registry is at capacity.
    private func evictIfNeeded() {
        guard historiesByThreadID.count >= evictionPolicy.maxEntries,
              let oldest = accessOrder.first else { return }
        historiesByThreadID.removeValue(forKey: oldest)
        accessOrder.removeFirst()
    }
}
