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

    /// Resolves the declarative prompt tree into an ordered ``AssembledPrompt``.
    ///
    /// The resulting artifact applies inherited traits and section ordering so it can
    /// be rendered, budgeted, or converted into provider-specific messages.
    ///
    /// - Returns: A fully assembled prompt artifact.
    public func assemble() -> AssembledPrompt {
        AssembledPrompt(
            resolvedSections: content.resolve(in: PromptResolutionContext())
        )
    }
}
