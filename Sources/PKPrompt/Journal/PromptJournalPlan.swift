import Foundation

/// Describes how a rendered prompt should be materialized into journal layers.
public struct PromptJournalPlan: Sendable {
    /// Describes how this plan should be emitted into conversation messages.
    public enum EmissionMode: Sendable, Equatable {
        /// Rebuild the full journal-backed prompt prefix from scratch.
        case snapshot
        /// Append only semistable updates plus current volatile messages.
        case delta
    }

    /// Sections that belong in the committed base layer.
    public let baseSections: [JournaledPromptSection]
    /// Semistable sections that should be written as an overlay for the current observation.
    public let overlaySections: [JournaledPromptSection]
    /// Sections that are always current-only and should not enter the committed base.
    public let volatileSections: [JournaledPromptSection]
    /// Indicates that stable content changed and downstream storage should discard prior journal state.
    public let requiresHardReset: Bool
    /// Semistable changes detected while producing this plan.
    public let diff: PromptJournalDiff
    /// Whether this observation should replace the stored journal prefix or append updates to it.
    public let emissionMode: EmissionMode

    /// Creates a journal plan.
    public init(
        baseSections: [JournaledPromptSection],
        overlaySections: [JournaledPromptSection],
        volatileSections: [JournaledPromptSection],
        requiresHardReset: Bool,
        diff: PromptJournalDiff,
        emissionMode: EmissionMode
    ) {
        self.baseSections = baseSections
        self.overlaySections = overlaySections
        self.volatileSections = volatileSections
        self.requiresHardReset = requiresHardReset
        self.diff = diff
        self.emissionMode = emissionMode
    }
}
