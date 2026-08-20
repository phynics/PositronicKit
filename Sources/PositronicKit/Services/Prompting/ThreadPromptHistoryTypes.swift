import Foundation
import PKPrompt
import PKContracts
import PKUtilities

public enum ThreadPromptHistoryError: PKError, Sendable, Equatable {
    case duplicateSectionIDs([String])

    public var errorDomain: String { PKErrorDomain.prompt }
    public var errorCode: Int { 1203 }
    public var userFriendlyMessage: String {
        "Prompt history contains duplicate section identifiers: \(duplicateIDs.joined(separator: ", "))."
    }
    public var remediation: String? { "Ensure every prompt section has a unique stable identifier." }

    private var duplicateIDs: [String] {
        switch self {
        case let .duplicateSectionIDs(ids): return ids
        }
    }
}

// MARK: - Snapshot Types

struct PromptSectionEntry {
    let entryId: String
    let contentHash: UInt64
    let cachePolicy: CachePolicy
    let estimatedTokens: Int
    let path: [String]
    let parentEntryId: String?
    let order: Int?
}

struct PromptSnapshot {
    let entries: [PromptSectionEntry]
}

struct PromptHistoryJournalDiff<Entry: Sendable> {
    struct SubtreeDiff {
        let changedNodePaths: [[String]]
        let stableNodePaths: [[String]]
        let addedNodePaths: [[String]]
        let removedNodePaths: [[String]]
    }

    let stablePrefixCount: Int
    let changed: [Entry]
    let added: [Entry]
    let removed: [Entry]
    let subtreeDiff: SubtreeDiff?

    var hasChanges: Bool {
        !changed.isEmpty || !added.isEmpty || !removed.isEmpty || {
            guard let subtreeDiff else { return false }
            return !subtreeDiff.changedNodePaths.isEmpty
                || !subtreeDiff.addedNodePaths.isEmpty
                || !subtreeDiff.removedNodePaths.isEmpty
        }()
    }
}

// MARK: - PromptDiff

struct PromptDiff {
    let journalDiff: PromptHistoryJournalDiff<PromptSectionEntry>

    /// Tokens in the positionally-stable prefix (cacheable by LLM).
    let stablePrefixTokens: Int

    var hasChanges: Bool {
        journalDiff.hasChanges
    }

    var stablePrefixCount: Int {
        journalDiff.stablePrefixCount
    }

    var changed: [PromptSectionEntry] {
        journalDiff.changed
    }

    var added: [PromptSectionEntry] {
        journalDiff.added
    }

    var removed: [String] {
        journalDiff.removed.map(\.entryId)
    }

    /// Policy-bearing removed entries, kept for the semistable-only journal projection.
    private var removedEntries: [PromptSectionEntry] {
        journalDiff.removed
    }

    var changedNodePaths: [[String]] {
        journalDiff.subtreeDiff?.changedNodePaths ?? []
    }

    var stableNodePaths: [[String]] {
        journalDiff.subtreeDiff?.stableNodePaths ?? []
    }

    var addedNodePaths: [[String]] {
        journalDiff.subtreeDiff?.addedNodePaths ?? []
    }

    var removedNodePaths: [[String]] {
        journalDiff.subtreeDiff?.removedNodePaths ?? []
    }

    var publicJournalDiff: PromptJournalDiff {
        PromptJournalDiff(
            changedSemiStableIDs: changed
                .filter { $0.cachePolicy == .semiStable }
                .map(\.entryId),
            addedSemiStableIDs: added
                .filter { $0.cachePolicy == .semiStable }
                .map(\.entryId),
            removedSemiStableIDs: removedEntries
                .filter { $0.cachePolicy == .semiStable }
                .map(\.entryId)
        )
    }
}

struct PromptHistoryUpdate {
    let diff: PromptDiff?
    let didCompact: Bool
}

// MARK: - Thresholds

/// Caps how many per-thread `ThreadPromptHistory` instances
/// `ThreadPromptJournals` keeps resident at once.
public struct RegistryEvictionPolicy: Sendable {
    /// Maximum number of threads the registry holds before it evicts the
    /// least-recently-accessed entry to make room for a new one.
    ///
    /// 1000 is a defensive process-lifetime cap, not a tuned capacity limit: a long-running
    /// `MonadServer` plausibly has many concurrent/recently-active threads resident at once,
    /// but not an unbounded number. This only bites when a consumer never calls
    /// `removeHistory(for:)` on thread deletion (the common case today -- see JRN-2).
    let maxEntries: Int

    public init(maxEntries: Int = 1000) {
        self.maxEntries = maxEntries
    }

    public static let `default` = RegistryEvictionPolicy()
}
