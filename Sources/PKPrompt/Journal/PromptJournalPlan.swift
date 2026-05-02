import Foundation

public struct PromptJournalPlan: Sendable {
    public let baseSections: [JournaledPromptSection]
    public let overlaySections: [JournaledPromptSection]
    public let volatileSections: [JournaledPromptSection]
    public let requiresHardReset: Bool
    public let diff: PromptJournalDiff

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

public struct PromptJournalDiff: Sendable, Equatable {
    public let changedSemiStableIDs: [String]
    public let addedSemiStableIDs: [String]
    public let removedSemiStableIDs: [String]

    public init(
        changedSemiStableIDs: [String] = [],
        addedSemiStableIDs: [String] = [],
        removedSemiStableIDs: [String] = []
    ) {
        self.changedSemiStableIDs = changedSemiStableIDs
        self.addedSemiStableIDs = addedSemiStableIDs
        self.removedSemiStableIDs = removedSemiStableIDs
    }

    public var hasOverlayChanges: Bool {
        !changedSemiStableIDs.isEmpty || !addedSemiStableIDs.isEmpty || !removedSemiStableIDs.isEmpty
    }
}
