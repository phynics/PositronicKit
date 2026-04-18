import Foundation

/// Lightweight wrapper for a declarative prompt definition.
public struct Prompt: Sendable {
    /// The root prompt composites that make up this declarative prompt tree.
    public let sections: [any PromptComposite]

    /// Creates a prompt from an explicit list of root sections.
    ///
    /// - Parameter sections: The declarative sections to validate and store.
    public init(sections: [any PromptComposite]) {
        try? validateUniqueSectionIDs(sections)
        self.sections = sections
    }

    /// Creates a prompt from a ``PromptBuilder`` closure.
    ///
    /// - Parameter content: A builder that produces the root prompt composite.
    public init(@PromptBuilder _ content: () -> some PromptComposite) {
        self.init(sections: [content()])
    }

    /// Resolves the declarative prompt tree into an ordered ``AssembledPrompt``.
    ///
    /// The resulting artifact applies inherited traits and section ordering so it can
    /// be rendered, budgeted, or converted into provider-specific messages.
    ///
    /// - Returns: A fully assembled prompt artifact.
    public func assemble() -> AssembledPrompt {
        AssembledPrompt(
            resolvedSections: sections.flatMap { $0.resolve(in: PromptResolutionContext()) }
        )
    }
}
