import Foundation

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
