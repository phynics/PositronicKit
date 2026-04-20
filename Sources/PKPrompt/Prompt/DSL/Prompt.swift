import Foundation

/// Lightweight wrapper for a declarative prompt definition.
public struct Prompt<Content: PromptComposite>: Sendable {
    /// The typed root composite that makes up this declarative prompt tree.
    public let content: Content

    /// Creates a prompt from an explicit root composite.
    ///
    /// - Parameter content: The declarative root composite to validate and store.
    public init(_ content: Content) {
        let duplicateIDs = content
            .resolve(in: PromptResolutionContext())
            .duplicateIDs(idKeyPath: \.id)
        precondition(
            duplicateIDs.isEmpty,
            "Duplicate context section ids in Prompt.init: \(duplicateIDs.joined(separator: ", "))"
        )
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
    public func assembledPrompt() -> AssembledPrompt {
        try! AssembledPrompt(resolvedSections: resolvedSections())
    }
}
