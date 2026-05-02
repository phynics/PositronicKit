import Foundation

public struct JournaledPromptSection: Sendable {
    public let section: RenderedPrompt.Section
    public let layer: PromptJournalLayer
    public let sourcePath: [String]
    public let journalPath: [String]

    public init(
        section: RenderedPrompt.Section,
        layer: PromptJournalLayer,
        sourcePath: [String],
        journalPath: [String]
    ) {
        self.section = section
        self.layer = layer
        self.sourcePath = sourcePath
        self.journalPath = journalPath
    }
}
