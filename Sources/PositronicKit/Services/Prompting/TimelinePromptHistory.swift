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

    /// Record a rendered prompt snapshot and compact append state if thresholds were exceeded.
    @discardableResult
    public func update(prompt: AssembledPrompt.RenderedPrompt) -> PromptHistoryUpdate {
        let diff = record(prompt: prompt)
        return PromptHistoryUpdate(diff: diff, didCompact: compactIfNeeded())
    }

    @discardableResult
    public func update(prompt: AssembledPrompt) async -> PromptHistoryUpdate {
        update(prompt: await prompt.render())
    }

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

    /// Record a rendered prompt snapshot without re-running prompt rendering.
    @discardableResult
    public func record(prompt: AssembledPrompt.RenderedPrompt) -> PromptDiff {
        let duplicateIDs = duplicateResolvedSectionIDs(in: prompt.sections)
        precondition(
            duplicateIDs.isEmpty,
            "Duplicate context section ids in TimelinePromptHistory.record: \(duplicateIDs.joined(separator: ", "))"
        )
        var entries: [PromptSectionEntry] = []
        for (index, section) in prompt.sections.enumerated() {
            let content = prompt.sectionsByID[section.id] ?? ""
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

    @discardableResult
    public func record(prompt: AssembledPrompt) async -> PromptDiff {
        record(prompt: await prompt.render())
    }

    @discardableResult
    public func record(sections: [AssembledPrompt.Section], renderedContent: [String: String]) -> PromptDiff {
        let renderedSections = sections.compactMap { section in
            renderedContent[section.id].map { content in
                AssembledPrompt.Section.Rendered(
                    id: section.id,
                    role: section.role,
                    priority: section.priority,
                    estimatedTokens: section.estimatedTokens,
                    compression: section.compression,
                    type: section.type,
                    cachePolicy: section.cachePolicy,
                    path: section.path,
                    parentID: section.parentID,
                    compressionOutcome: section.compressionOutcome,
                    content: .text(content)
                )
            }
        }

        return record(prompt: AssembledPrompt.RenderedPrompt(
            sections: renderedSections,
            string: renderedSections.compactMap { renderedContent[$0.id] }.joined(separator: "\n\n---\n\n"),
            sectionsByID: renderedContent
        ))
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
        prompt: AssembledPrompt.RenderedPrompt
    ) -> [String: StructuredNodeMetadata] {
        var metadata: [String: StructuredNodeMetadata] = [:]
        for section in prompt.sections {
            let content = prompt.sectionsByID[section.id] ?? ""
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

    private func duplicateResolvedSectionIDs(in sections: [AssembledPrompt.Section.Rendered]) -> [String] {
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
