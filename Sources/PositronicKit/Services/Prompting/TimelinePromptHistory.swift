import Foundation
import PKPrompt
import PKShared

// MARK: - Snapshot Types

struct PromptSectionEntry {
    let entryId: String
    let content: String
    let cachePolicy: CachePolicy
    let estimatedTokens: Int
    let path: [String]
    let parentEntryId: String?
    let order: Int?
    let sectionKind: PromptHistorySectionKind?

    var contentHash: UInt64 {
        var hasher = Hasher()
        content.hash(into: &hasher)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

struct PromptSnapshot {
    let entries: [PromptSectionEntry]
}

enum PromptHistorySectionKind: String, Codable, Hashable {
    case section
    case group
    case synthetic
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

public struct CompactionThresholds: Sendable {
    let maxAppendedTokens: Int
    let maxAppendedMessages: Int

    public init(maxAppendedTokens: Int = 50000, maxAppendedMessages: Int = 40) {
        self.maxAppendedTokens = maxAppendedTokens
        self.maxAppendedMessages = maxAppendedMessages
    }

    public static let `default` = CompactionThresholds()
}

/// Caps how many per-timeline `TimelinePromptHistory` instances
/// `TimelinePromptHistoryRegistry` keeps resident at once.
public struct RegistryEvictionPolicy: Sendable {
    /// Maximum number of timelines the registry holds before it evicts the
    /// least-recently-accessed entry to make room for a new one.
    ///
    /// 1000 is a defensive process-lifetime cap, not a tuned capacity limit: a long-running
    /// `MonadServer` plausibly has many concurrent/recently-active timelines resident at once,
    /// but not an unbounded number. This only bites when a consumer never calls
    /// `removeHistory(for:)` on conversation deletion (the common case today -- see JRN-2).
    let maxEntries: Int

    public init(maxEntries: Int = 1000) {
        self.maxEntries = maxEntries
    }

    public static let `default` = RegistryEvictionPolicy()
}

// MARK: - TimelinePromptHistory

// Runtime-only prompt diff/cache bookkeeping used by `PositronicKit` across turns.
//
// This actor is intentionally separate from `PKPrompt.PromptJournal`.
//
// - `PromptJournal` is the prompt-layer API for projecting prompt evolution into base/overlay /
//   volatile journal sections.
// - `TimelinePromptHistory` is runtime machinery for stable-prefix reuse, append-pressure
//   tracking, and compaction heuristics inside the chat loop.
//
// In other words: `PromptJournal` is a prompt-facing product surface, while this type is an
// implementation detail of the runtime orchestration layer.

/// Holds one `TimelinePromptHistory` per conversation timeline, so prompt-cache and
/// journal-diff state (the stable-prefix count, changed/added/removed semi-stable IDs)
/// accumulates across a conversation's sends rather than resetting on every call.
///
/// `ChatEngine+ContextBuilding.prepareSession` used to construct a fresh
/// `TimelinePromptHistory()` on every `execute` call, so `baseSnapshot` was always `nil`
/// at the start of every user turn — every send's first round-trip diffed against
/// nothing, always reporting `stablePrefixCount: 0` and everything "added" regardless of
/// how many prior turns the conversation actually had. Routing every call through this
/// registry keyed by `timelineId` fixes that: the second (and later) sends in a
/// conversation now diff against the previous send's final prompt snapshot.
public actor TimelinePromptHistoryRegistry {
    private var historiesByTimelineId: [UUID: TimelinePromptHistory] = [:]
    /// Timeline ids ordered from least- to most-recently accessed. The front of the array is
    /// the next eviction candidate. Kept as a plain array (not a generic LRU abstraction) --
    /// this registry isn't a hot path and entry counts are bounded by `evictionPolicy.maxEntries`.
    private var accessOrder: [UUID] = []
    private let thresholds: CompactionThresholds
    private let evictionPolicy: RegistryEvictionPolicy

    public init(
        thresholds: CompactionThresholds = .default,
        evictionPolicy: RegistryEvictionPolicy = .default
    ) {
        self.thresholds = thresholds
        self.evictionPolicy = evictionPolicy
    }

    /// Returns the existing history for `timelineId`, creating one on first use.
    ///
    /// Every call (whether it reuses an existing history or creates a new one) refreshes
    /// `timelineId`'s recency for LRU eviction purposes.
    public func history(for timelineId: UUID) -> TimelinePromptHistory {
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
    public func removeHistory(for timelineId: UUID) {
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
              let oldest = accessOrder.first
        else {
            return
        }
        historiesByTimelineId.removeValue(forKey: oldest)
        accessOrder.removeFirst()
    }
}

public actor TimelinePromptHistory {
    private var baseSnapshot: PromptSnapshot?
    private(set) var appendedMessageCount: Int = 0
    private(set) var appendedTokens: Int = 0
    let thresholds: CompactionThresholds
    private(set) var lastDiff: PromptDiff?

    /// The next inspection-turn index to assign for this timeline, persisted across
    /// `ChatEngine.execute` calls (i.e. across user sends), not just within one.
    ///
    /// `ChatTurnContext.turnCount` resets to 0 at the start of every `execute()` call, so it
    /// cannot be used as the persisted `TurnInspectionModel` row index — two different sends
    /// would both produce row index 0 for their first internal round-trip, and the second
    /// send's row would silently overwrite the first send's row (same `"timelineId:turnIndex"`
    /// key). This counter increments once per `nextInspectionTurnIndex()` call and is never
    /// reset, so every internal round-trip across the whole conversation gets a unique,
    /// monotonically increasing row index.
    private var nextInspectionIndex = 0

    init(thresholds: CompactionThresholds = .default) {
        self.thresholds = thresholds
    }

    /// Returns the next inspection-turn index for this timeline and advances the counter.
    func nextInspectionTurnIndex() -> Int {
        let index = nextInspectionIndex
        nextInspectionIndex += 1
        return index
    }

    /// Record a rendered prompt snapshot and compact append state if thresholds were exceeded.
    @discardableResult
    func update(prompt: RenderedPrompt) -> PromptHistoryUpdate {
        let diff = record(prompt: prompt)
        return PromptHistoryUpdate(diff: diff, didCompact: compactIfNeeded())
    }

    @discardableResult
    func update(prompt: AssembledPrompt) async -> PromptHistoryUpdate {
        update(prompt: await prompt.render())
    }

    @discardableResult
    func update(
        sections: [PromptSection],
        renderedContent: [String: String]
    ) -> PromptHistoryUpdate {
        let diff = record(sections: sections, renderedContent: renderedContent)
        return PromptHistoryUpdate(diff: diff, didCompact: compactIfNeeded())
    }

    /// Track appended messages and compact append state if thresholds were exceeded.
    @discardableResult
    func append(messages: [Message]) -> PromptHistoryUpdate {
        recordAppend(messages: messages)
        return PromptHistoryUpdate(diff: nil, didCompact: compactIfNeeded())
    }

    /// Track append pressure and compact append state if thresholds were exceeded.
    @discardableResult
    func append(messageCount: Int, estimatedTokens: Int) -> PromptHistoryUpdate {
        recordAppend(messageCount: messageCount, estimatedTokens: estimatedTokens)
        return PromptHistoryUpdate(diff: nil, didCompact: compactIfNeeded())
    }

    /// Record a rendered prompt snapshot without re-running prompt rendering.
    @discardableResult
    func record(prompt: RenderedPrompt) -> PromptDiff {
        let duplicateIDs = prompt.sections.duplicateIDs(idKeyPath: \.id)
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
    func record(prompt: AssembledPrompt) async -> PromptDiff {
        record(prompt: await prompt.render())
    }

    @discardableResult
    func record(sections: [PromptSection], renderedContent: [String: String]) -> PromptDiff {
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
    func recordAppend(messageCount: Int, estimatedTokens: Int) {
        appendedMessageCount += messageCount
        appendedTokens += estimatedTokens
    }

    /// Track concrete messages appended during the agentic loop.
    ///
    /// This is useful when a caller already has the appended messages and wants the history layer
    /// to estimate append pressure directly.
    func recordAppend(messages: [Message]) {
        recordAppend(
            messageCount: messages.count,
            estimatedTokens: PKShared.TokenEstimator.estimate(parts: messages.map(\.content))
        )
    }

    /// Whether the append chain has grown past thresholds.
    var shouldCompact: Bool {
        appendedTokens > thresholds.maxAppendedTokens
            || appendedMessageCount > thresholds.maxAppendedMessages
    }

    /// Reset append counters. Base snapshot is preserved for accurate future diffs.
    /// Call with `hard: true` to also clear the base (next record treats everything as new).
    func compact(hard: Bool = false) {
        if hard {
            baseSnapshot = nil
        }
        appendedMessageCount = 0
        appendedTokens = 0
        lastDiff = nil
    }

    func structuredDiffHint() -> StructuredDiffHint? {
        guard let lastDiff else { return nil }
        return StructuredDiffHint(
            changedNodePaths: lastDiff.changedNodePaths,
            stableNodePaths: lastDiff.stableNodePaths
        )
    }

    func nodeMetadata(
        prompt: RenderedPrompt
    ) -> [String: StructuredNodeMetadata] {
        var metadata: [String: StructuredNodeMetadata] = [:]
        for section in prompt.sections {
            let content = prompt.sectionsByID[section.id] ?? ""
            metadata[section.id] = section.nodeMetadata(renderedContent: content)
        }
        return metadata
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
               previous.entries[idx].contentHash == snapshot.entries[idx].contentHash
            {
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

        let removed = previous.entries.filter { !seenIds.contains($0.entryId) }

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
