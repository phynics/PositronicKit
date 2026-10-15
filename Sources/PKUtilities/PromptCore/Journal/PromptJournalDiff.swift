import Foundation

/// Describes semistable changes detected between the committed base and the current prompt.
public struct PromptJournalDiff: Sendable, Equatable {
    /// IDs of semistable sections whose content changed in the current prompt.
    public let changedSemiStableIDs: [String]
    /// IDs of semistable sections newly introduced in the current prompt.
    public let addedSemiStableIDs: [String]
    /// IDs of semistable sections that existed in the committed base but are now absent.
    public let removedSemiStableIDs: [String]

    /// Creates a semistable diff summary.
    public init(
        changedSemiStableIDs: [String] = [],
        addedSemiStableIDs: [String] = [],
        removedSemiStableIDs: [String] = []
    ) {
        self.changedSemiStableIDs = changedSemiStableIDs
        self.addedSemiStableIDs = addedSemiStableIDs
        self.removedSemiStableIDs = removedSemiStableIDs
    }

    /// Indicates whether any semistable overlay work is required for the current observation.
    public var hasOverlayChanges: Bool {
        !changedSemiStableIDs.isEmpty || !addedSemiStableIDs.isEmpty || !removedSemiStableIDs.isEmpty
    }
}
