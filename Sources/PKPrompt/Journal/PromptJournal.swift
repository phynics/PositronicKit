import Foundation

/// Tracks prompt snapshots across turns and projects them into journal layers.
///
/// `PromptJournal` keeps a committed non-volatile base, compares new rendered prompts against
/// that base, and produces a `PromptJournalPlan` describing which sections belong in the base,
/// overlay, and volatile layers for the current observation.
public struct PromptJournal: Sendable {
    private var committedBaseSections: [RenderedPrompt.Section] = []
    private var latestObservedSections: [RenderedPrompt.Section] = []

    /// Creates an empty prompt journal with no committed base.
    public init() {}

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

    /// Promotes the latest observed non-volatile sections into the committed base.
    ///
    /// Use compaction after an overlay has been accepted and should become the new baseline for
    /// future diffing.
    ///
    /// - Returns: A plan representing the compacted state, or `nil` when nothing has been observed.
    public mutating func compact() -> PromptJournalPlan? {
        guard !latestObservedSections.isEmpty else {
            return nil
        }

        committedBaseSections = latestObservedSections.filter { $0.cachePolicy != .volatile }
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
        if hard {
            committedBaseSections = []
        }
    }
}
