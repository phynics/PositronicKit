import Foundation

/// Describes how a rendered prompt should be materialized into journal layers.
public struct PromptJournalPlan: Sendable {
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

    /// Creates a journal plan.
    public init(
        baseSections: [JournaledPromptSection],
        overlaySections: [JournaledPromptSection],
        volatileSections: [JournaledPromptSection],
        requiresHardReset: Bool,
        diff: PromptJournalDiff
    ) {
        self.baseSections = baseSections
        self.overlaySections = overlaySections
        self.volatileSections = volatileSections
        self.requiresHardReset = requiresHardReset
        self.diff = diff
    }
}
