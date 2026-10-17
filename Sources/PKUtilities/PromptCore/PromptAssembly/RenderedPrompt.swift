import Foundation

/// Canonical prompt output derived from a single rendering pass.
public struct RenderedPrompt: Sendable {
    /// Rendered sections in canonical prompt order.
    public let sections: [RenderedPrompt.Section]

    /// Canonical plain-text prompt representation.
    public let string: String

    /// Plain-text content keyed by rendered section identifier.
    public let sectionsByID: [String: String]

    /// Optional compression details captured before rendering.
    public let compressionReport: CompressionReport?

    /// Estimated token count across rendered sections.
    public var estimatedTokens: Int {
        sections.reduce(0) { $0 + $1.estimatedTokens }
    }

    /// Creates a rendered prompt snapshot and its derived projections.
    public init(
        sections: [RenderedPrompt.Section],
        string: String,
        sectionsByID: [String: String],
        compressionReport: CompressionReport? = nil
    ) {
        self.sections = sections
        self.string = string
        self.sectionsByID = sectionsByID
        self.compressionReport = compressionReport
    }

    /// Returns a copy with replacement sections and every other value preserved.
    ///
    /// Runtime projections that rebuild section content use this so they never restate
    /// compression metadata they do not own.
    package func replacingSections(_ sections: [RenderedPrompt.Section]) -> RenderedPrompt {
        RenderedPrompt(
            sections: sections,
            string: string,
            sectionsByID: sectionsByID,
            compressionReport: compressionReport
        )
    }
}

