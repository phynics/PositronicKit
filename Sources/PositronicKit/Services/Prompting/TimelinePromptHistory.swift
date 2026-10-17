import Foundation
import PKContracts
import PKUtilities

// MARK: - TimelinePromptHistory

/// Process-scoped, runtime-only prompt state for one Timeline.
///
/// The runtime keeps no journal snapshots. A changed semi-stable segment is re-rendered in
/// place and reported as one prefix reset. This actor holds only the state the runtime reads
/// back across model rounds:
///
/// - the previous round's ``TierFingerprint`` for reset detection (#280),
/// - the stepwise history cut (#277),
/// - the history-projection coverage watermark,
/// - the newest retained sibling request (#281).
actor TimelinePromptHistory {
    /// The previous model round's ordered segment fingerprint, used to detect prefix resets (#280).
    private var lastTierFingerprint: TierFingerprint?
    /// Per-Timeline stepwise history cut (#277). Empty until the first over-budget Turn.
    private var trimState = HistoryTrimState()
    /// The durable message ID up to which the most recent applied history projection covered.
    private var historyProjectionCoverageWatermark: UUID?
    /// The most recent prompt-layout snapshot surfaced through `TimelineHandle.promptState()`.
    private var lastPromptState: PromptStateSnapshot?
    /// The newest final model round's provider-neutral request, or `nil` when sibling-prefix
    /// retention is disabled or no round has completed. Bounded to one entry per Timeline and
    /// released with this history entry on eviction or deletion.
    private var retainedSiblingRequest: RetainedSiblingRequest?

    /// The durable message ID up to which the most recent applied history projection covered.
    ///
    /// Process-scoped with the rest of the runtime prompt bookkeeping. `nil` means no projection is
    /// currently in effect for this Timeline, so the next ``TurnHistoryProjectionSource`` request is
    /// cold.
    func historyProjectionWatermark() -> UUID? {
        historyProjectionCoverageWatermark
    }

    /// Records the coverage boundary of the most recently applied history projection, or clears it
    /// when history was left raw.
    func recordHistoryProjectionWatermark(_ messageID: UUID?) {
        historyProjectionCoverageWatermark = messageID
    }

    /// The stepwise history cut currently in effect for this Timeline, or an empty state.
    func historyTrimState() -> HistoryTrimState {
        trimState
    }

    /// Persists the stepwise history cut after a trim pass so later Turns reuse the same prefix.
    func recordHistoryTrimState(_ state: HistoryTrimState) {
        trimState = state
    }

    /// Compares this round's rendered prompt against the previous round's and records the
    /// reusable-prefix accounting and the latest public prompt-state snapshot (#280).
    @discardableResult
    func accountPromptCache(
        prompt: RenderedPrompt,
        historyTrimmed: Bool,
        cachingEnabled: Bool,
        turnID: UUID,
        modelRoundIndex: Int,
        breakpoints: [PromptCacheBreakpoint]
    ) -> PromptCacheAccounting {
        let current = TierFingerprint(prompt: prompt)
        let accounting = PromptCacheResetDetector.account(
            previous: lastTierFingerprint,
            current: current,
            historyTrimmed: historyTrimmed,
            cachingEnabled: cachingEnabled
        )
        lastTierFingerprint = current
        lastPromptState = PromptStateSnapshot(
            turnID: turnID,
            modelRoundIndex: modelRoundIndex,
            fingerprint: current,
            breakpoints: breakpoints,
            resets: accounting.resets
        )
        return accounting
    }

    /// The latest prompt-layout state for this Timeline, or an empty snapshot before any round.
    func promptStateSnapshot() -> PromptStateSnapshot {
        lastPromptState ?? .empty
    }

    /// Retains the provider-neutral request the given model round sent.
    ///
    /// Each completed round overwrites the previous one, so the entry always describes the newest
    /// (and, once a Turn terminates, final) round. The retained value is never logged.
    func recordSiblingRequest(_ request: RetainedSiblingRequest) {
        retainedSiblingRequest = request
    }

    /// The newest retained final-round request, or `nil` when none was retained.
    func siblingRequest() -> RetainedSiblingRequest? {
        retainedSiblingRequest
    }
}
