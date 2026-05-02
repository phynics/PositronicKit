import Foundation
import PKPrompt
import PKShared

// MARK: - Snapshot Types

public struct PromptSectionEntry: Sendable {
    public let entryId: String
    public let content: String
    public let cachePolicy: CachePolicy
    public let estimatedTokens: Int
    public let path: [String]
    public let parentEntryId: String?
    public let order: Int?
    public let sectionKind: PromptHistorySectionKind?

    var contentHash: UInt64 {
        var hasher = Hasher()
        content.hash(into: &hasher)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

public struct PromptSnapshot: Sendable {
    public let entries: [PromptSectionEntry]
}

public enum PromptHistorySectionKind: String, Sendable, Codable, Hashable {
    case section
    case group
    case synthetic
}

struct PromptHistoryJournalDiff<Entry: Sendable>: Sendable {
    struct SubtreeDiff: Sendable {
        let changedNodePaths: [[String]]
        let stableNodePaths: [[String]]
        let addedNodePaths: [[String]]
        let removedNodePaths: [[String]]
    }

    let stablePrefixCount: Int
    let changed: [Entry]
    let added: [Entry]
    let removed: [String]
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

public struct PromptDiff: Sendable {
    let journalDiff: PromptHistoryJournalDiff<PromptSectionEntry>

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
    private var baseSnapshot: PromptSnapshot?
    public private(set) var appendedMessageCount: Int = 0
    public private(set) var appendedTokens: Int = 0
    public let thresholds: CompactionThresholds
    public private(set) var lastDiff: PromptDiff?

    public init(thresholds: CompactionThresholds = .default) {
        self.thresholds = thresholds
    }

    /// Record a rendered prompt snapshot and compact append state if thresholds were exceeded.
    @discardableResult
    public func update(prompt: RenderedPrompt) -> PromptHistoryUpdate {
        let diff = record(prompt: prompt)
        return PromptHistoryUpdate(diff: diff, didCompact: compactIfNeeded())
    }

    @discardableResult
    public func update(prompt: AssembledPrompt) async -> PromptHistoryUpdate {
        update(prompt: await prompt.render())
    }

    @discardableResult
    public func update(
        sections: [PromptSection],
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
    public func record(prompt: RenderedPrompt) -> PromptDiff {
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

        let genericDiff = diffAndCommit(PromptSnapshot(entries: entries))

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
    public func record(sections: [PromptSection], renderedContent: [String: String]) -> PromptDiff {
        let renderedSections = sections.compactMap { section in
            renderedContent[section.id].map { content in
                RenderedPrompt.Section(
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

        return record(prompt: RenderedPrompt(
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
        if hard {
            baseSnapshot = nil
        }
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
        prompt: RenderedPrompt
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
                    content
                ])
            )
        }
        return metadata
    }

    private func duplicateResolvedSectionIDs(in sections: [RenderedPrompt.Section]) -> [String] {
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

    private func diffAndCommit(_ snapshot: PromptSnapshot) -> PromptHistoryJournalDiff<PromptSectionEntry> {
        defer { baseSnapshot = snapshot }

        guard let previous = baseSnapshot else {
            let sortedAdded = snapshot.entries.map(\.path).sorted(by: pathLessThan)
            return PromptHistoryJournalDiff(
                stablePrefixCount: 0,
                changed: [],
                added: snapshot.entries,
                removed: [],
                subtreeDiff: .init(
                    changedNodePaths: [],
                    stableNodePaths: [],
                    addedNodePaths: sortedAdded,
                    removedNodePaths: []
                )
            )
        }

        var stablePrefixCount = 0
        for idx in 0 ..< min(previous.entries.count, snapshot.entries.count) {
            if previous.entries[idx].entryId == snapshot.entries[idx].entryId,
               previous.entries[idx].contentHash == snapshot.entries[idx].contentHash {
                stablePrefixCount += 1
            } else {
                break
            }
        }

        var previousById: [String: UInt64] = [:]
        for entry in previous.entries {
            previousById[entry.entryId] = entry.contentHash
        }

        var changed: [PromptSectionEntry] = []
        var added: [PromptSectionEntry] = []
        var seenIds: Set<String> = []
        for entry in snapshot.entries {
            seenIds.insert(entry.entryId)
            if let prevHash = previousById[entry.entryId] {
                if prevHash != entry.contentHash {
                    changed.append(entry)
                }
            } else {
                added.append(entry)
            }
        }

        let removed = previous.entries.map(\.entryId).filter { !seenIds.contains($0) }

        return PromptHistoryJournalDiff(
            stablePrefixCount: stablePrefixCount,
            changed: changed,
            added: added,
            removed: removed,
            subtreeDiff: buildSubtreeDiff(previous: previous.entries, current: snapshot.entries)
        )
    }

    private func buildSubtreeDiff(
        previous: [PromptSectionEntry],
        current: [PromptSectionEntry]
    ) -> PromptHistoryJournalDiff<PromptSectionEntry>.SubtreeDiff {
        func pathKey(_ path: [String]) -> String {
            path.map { "\($0.count):\($0)" }.joined(separator: "|")
        }

        var previousByPath: [String: UInt64] = [:]
        var pathLookup: [String: [String]] = [:]
        for entry in previous {
            let key = pathKey(entry.path)
            previousByPath[key] = entry.contentHash
            pathLookup[key] = entry.path
        }

        var stablePaths: [[String]] = []
        var changedPaths: [[String]] = []
        var addedPaths: [[String]] = []
        var seenPathKeys: Set<String> = []

        for entry in current {
            let key = pathKey(entry.path)
            seenPathKeys.insert(key)
            pathLookup[key] = entry.path

            if let previousHash = previousByPath[key] {
                if previousHash == entry.contentHash {
                    stablePaths.append(entry.path)
                } else {
                    changedPaths.append(entry.path)
                }
            } else {
                addedPaths.append(entry.path)
            }
        }

        let removedPaths = previousByPath.keys
            .filter { !seenPathKeys.contains($0) }
            .compactMap { pathLookup[$0] }

        return .init(
            changedNodePaths: changedPaths.sorted(by: pathLessThan),
            stableNodePaths: stablePaths.sorted(by: pathLessThan),
            addedNodePaths: addedPaths.sorted(by: pathLessThan),
            removedNodePaths: removedPaths.sorted(by: pathLessThan)
        )
    }

    private func pathLessThan(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.lexicographicallyPrecedes(rhs)
    }
}
