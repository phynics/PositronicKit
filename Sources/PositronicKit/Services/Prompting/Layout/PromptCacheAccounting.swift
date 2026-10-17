import Foundation
import PKContracts
import PKUtilities

/// The ordered per-segment content fingerprint of a rendered prompt.
///
/// The runtime uses this small value — rather than journal snapshots — to decide which tiers
/// carried over byte-for-byte from the previous model round and which reset. It is process-scoped
/// and never persisted raw.
struct TierFingerprint: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        let id: String
        let tier: PromptCacheTier
        let contentHash: UInt64
        let estimatedTokens: Int
    }

    let segments: [Segment]

    init(segments: [Segment]) {
        self.segments = segments
    }

    init(prompt: RenderedPrompt) {
        segments = prompt.sections.map { section in
            Segment(
                id: section.id,
                tier: PromptLayoutBuilder.tier(for: section),
                contentHash: sectionContentHash(section.content),
                estimatedTokens: section.estimatedTokens
            )
        }
    }

    /// The combined fingerprint string for one tier.
    func fingerprint(for tier: PromptCacheTier) -> String {
        var components: [String] = []
        for segment in segments where segment.tier == tier {
            components.append(segment.id)
            components.append(String(segment.contentHash))
        }
        return String(format: "%016llx", StableHash.hash(components: components))
    }

    /// An empty fingerprint, for a round with no assembled prompt to account for.
    static let empty = TierFingerprint(segments: [])
}

/// The outcome of comparing one round's ``TierFingerprint`` to the previous round's.
struct PromptCacheAccounting: Sendable, Equatable {
    let expectedReusableTokens: Int
    let resets: [PromptCacheReport.ResetReason]
}

/// Compares consecutive round fingerprints to produce the reset reasons and reusable-token count.
enum PromptCacheResetDetector {
    private static let toolsSegmentID = "tools"
    private static let historyProjectionSegmentID = "runtime.history-projection"

    static func account(
        previous: TierFingerprint?,
        current: TierFingerprint,
        historyTrimmed: Bool,
        cachingEnabled: Bool
    ) -> PromptCacheAccounting {
        guard cachingEnabled else {
            return PromptCacheAccounting(expectedReusableTokens: 0, resets: [.cachingDisabled])
        }
        guard let previous else {
            return PromptCacheAccounting(expectedReusableTokens: 0, resets: [.firstRound])
        }

        let expectedReusableTokens = leadingReusableTokens(previous: previous, current: current)
        var resets: [PromptCacheReport.ResetReason] = []

        if segmentChanged(previous: previous, current: current, where: { $0.id == toolsSegmentID }) {
            resets.append(.toolsChanged)
        }

        if previous.fingerprint(for: .stable) != current.fingerprint(for: .stable) {
            resets.append(.stableTierChanged)
        }

        let semiStableChangedIDs = changedSegmentIDs(
            previous: previous,
            current: current,
            where: { $0.tier == .semiStable && $0.id != toolsSegmentID }
        )
        if semiStableChangedIDs == [historyProjectionSegmentID] {
            resets.append(.historyProjectionChanged)
        } else if !semiStableChangedIDs.isEmpty {
            resets.append(.semiStableSegmentChanged)
        }

        if historyTrimmed {
            resets.append(.historyTrim)
        }

        return PromptCacheAccounting(expectedReusableTokens: expectedReusableTokens, resets: resets)
    }

    /// Tokens in the leading run of segments whose identity and content match the previous round.
    private static func leadingReusableTokens(previous: TierFingerprint, current: TierFingerprint) -> Int {
        var tokens = 0
        for index in 0 ..< min(previous.segments.count, current.segments.count) {
            let prior = previous.segments[index]
            let next = current.segments[index]
            guard prior.id == next.id, prior.contentHash == next.contentHash else {
                break
            }
            tokens += next.estimatedTokens
        }
        return tokens
    }

    /// Whether any segment selected by `where` changed identity or content between rounds.
    private static func segmentChanged(
        previous: TierFingerprint,
        current: TierFingerprint,
        where predicate: (TierFingerprint.Segment) -> Bool
    ) -> Bool {
        !changedSegmentIDs(previous: previous, current: current, where: predicate).isEmpty
    }

    /// The IDs of segments selected by `where` that were added, removed, or changed.
    private static func changedSegmentIDs(
        previous: TierFingerprint,
        current: TierFingerprint,
        where predicate: (TierFingerprint.Segment) -> Bool
    ) -> [String] {
        var previousByID: [String: UInt64] = [:]
        for segment in previous.segments where predicate(segment) {
            previousByID[segment.id] = segment.contentHash
        }
        var changedIDs: [String] = []
        var seen: Set<String> = []
        for segment in current.segments where predicate(segment) {
            seen.insert(segment.id)
            if previousByID[segment.id] != segment.contentHash {
                changedIDs.append(segment.id)
            }
        }
        for segment in previous.segments where predicate(segment) && !seen.contains(segment.id) {
            changedIDs.append(segment.id)
        }
        return changedIDs
    }
}

/// The public, value-only view of the runtime's prompt layout state for one Timeline.
///
/// `promptState()` returns this snapshot so a host can inspect the layout segment IDs and tiers,
/// the per-tier fingerprints, the last request's cache breakpoints, and the last reset reasons
/// without holding a runtime actor or duplicating prompt bookkeeping.
public struct PromptStateSnapshot: Sendable, Hashable, Codable {
    /// One layout segment's identity, tier, and content fingerprint.
    public struct Segment: Sendable, Hashable, Codable {
        /// The stable segment identifier shared with the assembled section.
        public let id: String
        /// The cache tier the segment belongs to.
        public let tier: PromptCacheTier
        /// A stable content fingerprint for the segment.
        public let fingerprint: String
        /// The segment's estimated token count.
        public let estimatedTokens: Int

        public init(id: String, tier: PromptCacheTier, fingerprint: String, estimatedTokens: Int) {
            self.id = id
            self.tier = tier
            self.fingerprint = fingerprint
            self.estimatedTokens = estimatedTokens
        }
    }

    /// One tier's combined fingerprint.
    public struct Tier: Sendable, Hashable, Codable {
        /// The tier this fingerprint covers.
        public let tier: PromptCacheTier
        /// A stable fingerprint of every segment in the tier.
        public let fingerprint: String
        /// The tier's estimated token count.
        public let estimatedTokens: Int

        public init(tier: PromptCacheTier, fingerprint: String, estimatedTokens: Int) {
            self.tier = tier
            self.fingerprint = fingerprint
            self.estimatedTokens = estimatedTokens
        }
    }

    /// The Turn whose round last refreshed this snapshot, when any.
    public let turnID: UUID?
    /// The model round that last refreshed this snapshot, when any.
    public let modelRoundIndex: Int?
    /// The ordered layout segments.
    public let segments: [Segment]
    /// The per-tier combined fingerprints.
    public let tiers: [Tier]
    /// The cache breakpoints of the last request.
    public let breakpoints: [PromptCacheBreakpoint]
    /// The reset reasons reported for the last request.
    public let resets: [PromptCacheReport.ResetReason]

    public init(
        turnID: UUID? = nil,
        modelRoundIndex: Int? = nil,
        segments: [Segment] = [],
        tiers: [Tier] = [],
        breakpoints: [PromptCacheBreakpoint] = [],
        resets: [PromptCacheReport.ResetReason] = []
    ) {
        self.turnID = turnID
        self.modelRoundIndex = modelRoundIndex
        self.segments = segments
        self.tiers = tiers
        self.breakpoints = breakpoints
        self.resets = resets
    }

    /// An empty snapshot for a Timeline with no prepared prompt yet.
    public static let empty = PromptStateSnapshot()

    init(
        turnID: UUID,
        modelRoundIndex: Int,
        fingerprint: TierFingerprint,
        breakpoints: [PromptCacheBreakpoint],
        resets: [PromptCacheReport.ResetReason]
    ) {
        self.turnID = turnID
        self.modelRoundIndex = modelRoundIndex
        segments = fingerprint.segments.map { segment in
            Segment(
                id: segment.id,
                tier: segment.tier,
                fingerprint: String(format: "%016llx", segment.contentHash),
                estimatedTokens: segment.estimatedTokens
            )
        }
        tiers = PromptCacheTier.allCases.map { tier in
            Tier(
                tier: tier,
                fingerprint: fingerprint.fingerprint(for: tier),
                estimatedTokens: fingerprint.segments
                    .filter { $0.tier == tier }
                    .reduce(0) { $0 + $1.estimatedTokens }
            )
        }
        self.breakpoints = breakpoints
        self.resets = resets
    }
}
