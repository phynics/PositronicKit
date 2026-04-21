import Foundation

/// Result builder for authoring declarative prompt trees.
///
/// The builder lowers authored control flow into semantic composites such as
/// ``PromptConditional``, ``PromptForEach``, and ``PromptOptional`` while preserving the
/// concrete authored composite types wherever possible.
///
/// ```swift
/// let prompt = AnyPrompt.build {
///     SystemPrompt("You are helpful.")
///
///     if includeHistory {
///         AnyPrompt.build {
///             HistoryPrompt(messages)
///         }
///     }
///
///     for item in items {
///         UserPrompt(item)
///     }
/// }
/// ```
@resultBuilder
public enum PromptBuilder {
    public typealias Component = PromptBlock
    
    /// Wraps authored siblings in a typed block.
    public static func buildBlock<Content: Prompt>(_ content: Content) -> Content {
        content
    }

    /// Wraps authored siblings in a typed block.
    public static func buildBlock<each Content: Prompt>(
        _ content: repeat each Content
    ) -> PromptBlock<repeat each Content> {
        PromptBlock(repeat each content)
    }
    
    /// Preserves a single prompt composite expression without extra wrapping.
    public static func buildExpression<S: Prompt>(_ section: S) -> S {
        section
    }

    /// Wraps an explicit list of prompt composites for further builder composition.
    public static func buildExpression(_ sections: [any Prompt]) -> AnyPrompt {
        AnyPrompt(sections)
    }

    /// Lowers an optional branch into ``PromptOptional``.
    public static func buildOptional<Content: Prompt>(
        _ component: Content?
    ) -> PromptOptional<Content, EmptySection> {
        // Preserve the authored optional node even when the branch resolves to nil so
        // downstream prompt introspection can still see that an optional boundary existed.
        PromptOptional(primary: component)
    }

    /// Lowers the selected `if` branch into ``PromptConditional``.
    public static func buildEither<TrueContent: Prompt, FalseContent: Prompt>(
        first component: TrueContent
    ) -> PromptConditional<TrueContent, FalseContent> {
        PromptConditional(first: component)
    }

    /// Lowers the selected `else` branch into ``PromptConditional``.
    public static func buildEither<TrueContent: Prompt, FalseContent: Prompt>(
        second component: FalseContent
    ) -> PromptConditional<TrueContent, FalseContent> {
        PromptConditional(second: component)
    }

    /// Lowers repeated builder output into ``PromptForEach``.
    public static func buildArray<Content: Prompt>(_ components: [Content]) -> PromptForEach<Content> {
        // Keep the loop as a first-class composite instead of flattening immediately so
        // later phases can distinguish authored repetition from ordinary sibling sections.
        PromptForEach(components)
    }

    /// Ignores expressions that produce no prompt content.
    public static func buildExpression(_: Void) -> EmptySection {
        EmptySection()
    }

    /// Returns the fully lowered root prompt content.
    public static func buildFinalResult<Content: Prompt>(_ component: Content) -> Content {
        component
    }
}
