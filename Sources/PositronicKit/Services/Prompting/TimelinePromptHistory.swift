import Foundation
import PKPrompt
import PKShared

// MARK: - Snapshot Types

public struct PromptSectionEntry: PipelineSnapshotEntry, Sendable {
    public let entryId: String
    public let content: String
    public let cachePolicy: CachePolicy
    public let estimatedTokens: Int
    public let path: [String]
    public let parentEntryId: String?
    public let order: Int?
    public let sectionKind: PipelineSnapshotSectionKind?
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

    public var changedNodePaths: [[String]] {
        journalDiff.subtreeDiff?.changedNodePaths ?? []
    }

    public var stableNodePaths: [[String]] {
        journalDiff.subtreeDiff?.stableNodePaths ?? []
    }

    public var addedNodePaths: [[String]] {
        journalDiff.subtreeDiff?.addedNodePaths ?? []
    }

    public var removedNodePaths: [[String]] {
        journalDiff.subtreeDiff?.removedNodePaths ?? []
    }
}

public struct PromptHistoryUpdate: Sendable {
    public let diff: PromptDiff?
    public let didCompact: Bool
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

    /// Record a prompt snapshot and compact append state if thresholds were exceeded.
    @discardableResult
    public func update(prompt: AssembledPrompt) async -> PromptHistoryUpdate {
        let rendered = await prompt.render()
        return update(prompt: prompt, rendered: rendered)
    }

    /// Record a prompt snapshot from an existing rendered product and compact append state if needed.
    @discardableResult
    public func update(
        prompt: AssembledPrompt,
        rendered: AssembledPrompt.RenderedPrompt
    ) -> PromptHistoryUpdate {
        let diff = record(prompt: prompt, rendered: rendered)
        return PromptHistoryUpdate(diff: diff, didCompact: compactIfNeeded())
    }

    /// Record a prompt snapshot from concrete sections and rendered content, compacting if needed.
    @discardableResult
    public func update(
        sections: [AssembledPrompt.Section],
        renderedContent: [String: String]
    ) -> PromptHistoryUpdate {
        let diff = record(sections: sections, renderedContent: renderedContent)
        return PromptHistoryUpdate(diff: diff, didCompact: compactIfNeeded())
    }

    /// Track appended messages and compact append state if thresholds were exceeded.
    @discardableResult
    public func append(messages: [Message]) -> PromptHistoryUpdate {
        recordAppend(messages: messages)
        return PromptHistoryUpdate(diff: nil, didCompact: compactIfNeeded())
    }

    /// Track append pressure and compact append state if thresholds were exceeded.
    @discardableResult
    public func append(messageCount: Int, estimatedTokens: Int) -> PromptHistoryUpdate {
        recordAppend(messageCount: messageCount, estimatedTokens: estimatedTokens)
        return PromptHistoryUpdate(diff: nil, didCompact: compactIfNeeded())
    }

    /// Render and record an assembled prompt in one step.
    ///
    /// Use this when prompt structure itself is the unit you want to journal for stable-prefix
    /// detection and prefix-caching-aware history tracking.
    @discardableResult
    public func record(prompt: AssembledPrompt) async -> PromptDiff {
        let rendered = await prompt.render()
        return record(prompt: prompt, rendered: rendered)
    }

    /// Record an assembled prompt from an existing canonical rendered product.
    ///
    /// - Parameters:
    ///   - prompt: The assembled prompt that provides section metadata and ordering.
    ///   - rendered: The canonical rendered prompt product previously produced from `prompt`.
    /// - Returns: A diff describing what changed since the last recording.
    @discardableResult
    public func record(
        prompt: AssembledPrompt,
        rendered: AssembledPrompt.RenderedPrompt
    ) -> PromptDiff {
        record(sections: prompt.sections, renderedContent: rendered.sectionsByID)
    }

    /// Record a prompt snapshot using pre-rendered content (avoids double-rendering).
    ///
    /// - Parameters:
    ///   - sections: The prompt's resolved ordered sections (used for metadata).
    ///   - renderedContent: Map of section ID to rendered string. Sections not in this map
    ///     are hashed as empty string.
    /// - Returns: A diff describing what changed since the last recording.
    @discardableResult
    public func record(sections: [AssembledPrompt.Section], renderedContent: [String: String]) -> PromptDiff {
        let duplicateIDs = duplicateResolvedSectionIDs(in: sections)
        precondition(
            duplicateIDs.isEmpty,
            "Duplicate context section ids in TimelinePromptHistory.record: \(duplicateIDs.joined(separator: ", "))"
        )
        var entries: [PromptSectionEntry] = []
        for (index, section) in sections.enumerated() {
            let content = renderedContent[section.id] ?? ""
            entries.append(PromptSectionEntry(
                entryId: section.id,
                content: content,
                cachePolicy: section.cachePolicy,
                estimatedTokens: section.estimatedTokens,
                path: section.path,
                parentEntryId: section.parentID,
                order: index,
                sectionKind: section.type == .list ? .group : .section
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

    /// Track concrete messages appended during the agentic loop.
    ///
    /// This is useful when a caller already has the appended messages and wants the history layer
    /// to estimate append pressure directly.
    public func recordAppend(messages: [Message]) {
        recordAppend(
            messageCount: messages.count,
            estimatedTokens: TokenEstimator.estimate(parts: messages.map(\.content))
        )
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

    public func structuredDiffHint() -> StructuredDiffHint? {
        guard let lastDiff else { return nil }
        return StructuredDiffHint(
            changedNodePaths: lastDiff.changedNodePaths,
            stableNodePaths: lastDiff.stableNodePaths
        )
    }

    public func nodeMetadata(
        sections: [AssembledPrompt.Section],
        renderedContent: [String: String]
    ) -> [String: StructuredNodeMetadata] {
        var metadata: [String: StructuredNodeMetadata] = [:]
        for section in sections {
            let content = renderedContent[section.id] ?? ""
            let path = section.path
            metadata[section.id] = StructuredNodeMetadata(
                path: path,
                nodeHash: StableHash.hash(components: [
                    section.id,
                    String(section.estimatedTokens),
                    String(section.priority),
                    String(describing: section.cachePolicy),
                    content,
                ])
            )
        }
        return metadata
    }

    private func duplicateResolvedSectionIDs(in sections: [AssembledPrompt.Section]) -> [String] {
        var counts: [String: Int] = [:]
        for section in sections {
            counts[section.id, default: 0] += 1
        }

        return counts
            .filter { $0.value > 1 }
            .map(\.key)
            .sorted()
    }

    private func compactIfNeeded() -> Bool {
        guard shouldCompact else {
            return false
        }
        compact()
        return true
    }
}
