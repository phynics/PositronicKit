import Foundation
import PKPrompt

// MARK: - Snapshot Types

public struct PromptSectionEntry: PipelineSnapshotEntry, Sendable {
    public let entryId: String
    public let content: String
    public let cachePolicy: CachePolicy
    public let estimatedTokens: Int
}

public struct PromptSnapshot: PipelineSnapshot, Sendable {
    public let entries: [PromptSectionEntry]
}

// MARK: - PromptDiff

public struct PromptDiff: Sendable {
    let journalDiff: JournalDiff<PromptSectionEntry>

    /// Tokens in the positionally-stable prefix (cacheable by LLM).
    public let stablePrefixTokens: Int

    public var hasChanges: Bool {
        journalDiff.hasChanges
    }

    public var stablePrefixCount: Int {
        journalDiff.stablePrefixCount
    }

    public var changed: [PromptSectionEntry] {
        journalDiff.changed
    }

    public var added: [PromptSectionEntry] {
        journalDiff.added
    }

    public var removed: [String] {
        journalDiff.removed
    }
}

// MARK: - Thresholds

public struct CompactionThresholds: Sendable {
    public let maxAppendedTokens: Int
    public let maxAppendedMessages: Int

    public init(maxAppendedTokens: Int = 50000, maxAppendedMessages: Int = 40) {
        self.maxAppendedTokens = maxAppendedTokens
        self.maxAppendedMessages = maxAppendedMessages
    }

    public static let `default` = CompactionThresholds()
}

// MARK: - TimelinePromptHistory

public actor TimelinePromptHistory {
    private var journal: PipelineJournal<PromptSnapshot>
    public private(set) var appendedMessageCount: Int = 0
    public private(set) var appendedTokens: Int = 0
    public let thresholds: CompactionThresholds
    public private(set) var lastDiff: PromptDiff?

    public init(thresholds: CompactionThresholds = .default) {
        journal = PipelineJournal<PromptSnapshot>()
        self.thresholds = thresholds
    }

    /// Record a prompt snapshot using pre-rendered content (avoids double-rendering).
    ///
    /// - Parameters:
    ///   - sections: The prompt's ordered sections (used for metadata).
    ///   - renderedContent: Map of section ID to rendered string. Sections not in this map
    ///     are hashed as empty string.
    /// - Returns: A diff describing what changed since the last recording.
    @discardableResult
    public func record(sections: [ContextSection], renderedContent: [String: String]) -> PromptDiff {
        var entries: [PromptSectionEntry] = []
        for section in sections {
            let content = renderedContent[section.id] ?? ""
            entries.append(PromptSectionEntry(
                entryId: section.id,
                content: content,
                cachePolicy: section.cachePolicy,
                estimatedTokens: section.estimatedTokens
            ))
        }

        let genericDiff = journal.record(PromptSnapshot(entries: entries))

        let prefixTokens = entries.prefix(genericDiff.stablePrefixCount)
            .reduce(0) { $0 + $1.estimatedTokens }

        let diff = PromptDiff(
            journalDiff: genericDiff,
            stablePrefixTokens: prefixTokens
        )
        lastDiff = diff
        return diff
    }

    /// Track messages appended during the agentic loop (assistant responses, tool results).
    public func recordAppend(messageCount: Int, estimatedTokens: Int) {
        appendedMessageCount += messageCount
        appendedTokens += estimatedTokens
    }

    /// Whether the append chain has grown past thresholds.
    public var shouldCompact: Bool {
        appendedTokens > thresholds.maxAppendedTokens
            || appendedMessageCount > thresholds.maxAppendedMessages
    }

    /// Reset append counters. Base snapshot is preserved for accurate future diffs.
    /// Call with `hard: true` to also clear the base (next record treats everything as new).
    public func compact(hard: Bool = false) {
        journal.compact(hard: hard)
        appendedMessageCount = 0
        appendedTokens = 0
        lastDiff = nil
    }
}
