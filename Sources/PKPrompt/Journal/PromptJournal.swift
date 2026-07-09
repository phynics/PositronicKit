import Foundation
import PKShared

/// Tracks prompt snapshots across turns and projects them into journal layers.
///
/// `PromptJournal` keeps a committed non-volatile base, compares new rendered prompts against
/// that base, and produces a `PromptJournalPlan` describing which sections belong in the base,
/// overlay, and volatile layers for the current observation.
///
/// This is the prompt-layer journaling abstraction intended for public use. Reach for it when you
/// want to reason about prompt evolution directly, outside the runtime loop.
public struct PromptJournal: Sendable {
    private var pressure: AppendPressure
    private var committedBaseSections: [RenderedPrompt.Section] = []
    private var latestObservedSections: [RenderedPrompt.Section] = []

    /// Creates an empty prompt journal with no committed base.
    ///
    /// - Parameter thresholds: Append-pressure thresholds that trigger auto-compaction of the
    ///   latest accepted observation into a new committed base on the next `observe(_:)`.
    public init(thresholds: PromptJournalCompactionThresholds = .default) {
        self.pressure = AppendPressure(thresholds: thresholds)
    }

    /// Observes a rendered prompt and returns the journal plan for the current turn.
    ///
    /// The first observation materializes all non-volatile sections into the committed base.
    /// Subsequent observations emit semistable changes as overlay sections unless stable content
    /// changes, in which case the base is rebuilt and the returned plan requests a hard reset.
    ///
    /// - Parameter prompt: The rendered prompt snapshot to journal.
    /// - Returns: A plan describing the current base, overlay, and volatile layers.
    public mutating func observe(_ prompt: RenderedPrompt) -> PromptJournalPlan {
        let currentSections = prompt.sections
        compactIfNeeded()
        defer { latestObservedSections = currentSections }

        let evaluation = PromptJournalDiffer.evaluate(
            committedBaseSections: committedBaseSections,
            currentSections: currentSections
        )
        committedBaseSections = evaluation.nextCommittedBaseSections

        return PromptJournalPlanBuilder.makePlan(
            committedBaseSections: committedBaseSections,
            currentSections: currentSections,
            overlaySections: evaluation.overlaySections,
            requiresHardReset: evaluation.requiresHardReset,
            diff: evaluation.diff,
            emissionMode: evaluation.emissionMode
        )
    }

    /// Records append pressure from accepted downstream conversation messages.
    ///
    /// Use this after the current journal observation has been accepted by a caller and appended
    /// to conversation history. When append pressure exceeds `thresholds`, the journal promotes
    /// the latest accepted observation into a new committed base on the next `observe(_:)`.
    public mutating func recordAppend(messageCount: Int, estimatedTokens: Int) {
        pressure.recordAppend(messageCount: messageCount, estimatedTokens: estimatedTokens)
    }

    /// Records append pressure from concrete appended messages.
    public mutating func recordAppend(messages: [Message]) {
        pressure.recordAppend(messages: messages)
    }

    /// Whether the latest accepted observation should be compacted before the next diff.
    public var shouldCompact: Bool {
        pressure.shouldCompact
    }

    /// Promotes the latest observed non-volatile sections into the committed base.
    ///
    /// Use compaction after an overlay has been accepted and should become the new baseline for
    /// future diffing.
    ///
    /// - Returns: A plan representing the compacted state, or `nil` when nothing has been observed.
    public mutating func compact() -> PromptJournalPlan? {
        guard !latestObservedSections.isEmpty else {
            pressure.reset()
            return nil
        }

        committedBaseSections = latestObservedSections.filter { $0.cachePolicy != .volatile }
        pressure.reset()
        return PromptJournalPlanBuilder.makePlan(
            committedBaseSections: committedBaseSections,
            currentSections: latestObservedSections,
            overlaySections: [],
            requiresHardReset: false,
            diff: PromptJournalDiff(),
            emissionMode: .snapshot
        )
    }

    /// Clears the current observation state.
    ///
    /// - Parameter hard: When `true`, also clears the committed base so the next observation starts
    ///   from an empty journal.
    public mutating func reset(hard: Bool = false) {
        latestObservedSections = []
        pressure.reset()
        if hard {
            committedBaseSections = []
        }
    }

    private mutating func compactIfNeeded() {
        guard pressure.shouldCompact else {
            return
        }
        if !latestObservedSections.isEmpty {
            committedBaseSections = latestObservedSections.filter { $0.cachePolicy != .volatile }
        }
        pressure.reset()
    }
}
