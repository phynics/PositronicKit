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
