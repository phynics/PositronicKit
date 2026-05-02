import Foundation
import PKShared

/// A validated, ordered prompt artifact built from concrete prompt sections.
///
/// `AssembledPrompt` is the bridge between declarative prompt composition and concrete output.
/// It preserves the concrete section metadata used by downstream systems and renders those
/// sections into a single canonical ``RenderedPrompt`` product that can be reused by downstream
/// projections such as provider message arrays.
public struct AssembledPrompt: Sendable {
    /// Compatibility alias for prompt assembly validation failures.
    public typealias ValidationError = PromptAssemblyError

    // MARK: - Properties

    /// Ordered concrete sections that make up this prompt.
    ///
    /// Sections are sorted during initialization by cache policy, then priority, while preserving
    /// source order as a final tiebreaker.
    public let sections: [PromptSection]

    /// Optional compression details captured when assembly applied a token budget.
    public let compressionReport: CompressionReport?

    /// Estimated token count across the ordered concrete sections.
    public var estimatedTokens: Int {
        PromptSection.estimatedTokens(in: sections)
    }

    /// Creates an assembled prompt from concrete sections after validating prompt shape.
    ///
    /// - Parameters:
    ///   - sections: Concrete prompt sections to validate and order.
    ///   - compressionReport: Optional report describing compression applied during assembly.
    /// - Throws: ``ValidationError`` when duplicate section identifiers are present or the prompt
    ///   contains more than one user-query section.
    public init(
        sections: [PromptSection],
        compressionReport: CompressionReport? = nil,
    ) throws {
        self.sections = try PromptSection.validateAndSort(sections: sections)
        self.compressionReport = compressionReport
    }

    /// Renders the prompt once and returns its canonical output product.
    ///
    /// Prefer this API when multiple downstream consumers need access to the same rendered prompt,
    /// such as plain-text rendering, snapshot recording, and provider message generation.
    public func render() async -> RenderedPrompt {
        await RenderedPrompt.render(sections: sections, compressionReport: compressionReport)
    }
}
