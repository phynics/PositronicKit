import Foundation

/// Lightweight wrapper for a declarative prompt definition.
public struct Prompt<Content: PromptComposite>: Sendable {
    /// The typed root composite that makes up this declarative prompt tree.
    public let content: Content

    /// Creates a prompt from an explicit root composite.
    ///
    /// - Parameter content: The declarative root composite to validate and store.
    public init(_ content: Content) {
        PromptSectionValidator.assertUniqueIDs(in: [content], context: "Prompt.init")
        self.content = content
    }

    /// Creates a prompt from a ``PromptBuilder`` closure.
    ///
    /// - Parameter content: A builder that produces the root prompt composite.
    public init(@PromptBuilder _ content: () -> Content) {
        self.init(content())
    }

    /// Resolves the declarative prompt tree into concrete prompt sections.
    public func resolvedSections() -> [ResolvedPromptSection] {
        content.resolve(in: PromptResolutionContext())
    }

    /// Assembles the declarative prompt tree into an ordered ``AssembledPrompt``.
    public func assembledPrompt() throws -> AssembledPrompt {
        try AssembledPrompt(
            resolvedSections: resolvedSections()
        )
    }
}
