import Foundation

/// A rendered prompt section annotated with its journal layer and storage paths.
public struct JournaledPromptSection: Sendable {
    /// The destination layer for a journaled section.
    public enum JournalLayer: Sendable, Equatable {
        /// A committed section that remains stable across observations.
        case base
        /// A semistable section emitted only for the current observation.
        case overlay
        /// A current-only section that is never committed into the base.
        case volatile
    }

    /// The rendered prompt section payload.
    public let section: RenderedPrompt.Section
    /// The journal layer that should receive this section.
    public let layer: JournalLayer
    /// The section's original path in the rendered prompt tree.
    public let sourcePath: [String]
    /// The normalized path used when writing the section into journal storage.
    public let journalPath: [String]

    /// Creates a journaled prompt section.
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
