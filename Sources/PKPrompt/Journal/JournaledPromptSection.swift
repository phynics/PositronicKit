import Foundation

public struct JournaledPromptSection: Sendable {
    public enum JournalLayer: Sendable, Equatable {
        case base
        case overlay
        case volatile
    }

    public let section: RenderedPrompt.Section
    public let layer: JournalLayer
    public let sourcePath: [String]
    public let journalPath: [String]

    public init(
        section: RenderedPrompt.Section,
        layer: JournalLayer,
        sourcePath: [String],
        journalPath: [String]
    ) {
        self.section = section
        self.layer = layer
        self.sourcePath = sourcePath
        self.journalPath = journalPath
    }
}
