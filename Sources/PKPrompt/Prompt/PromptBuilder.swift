import Foundation

/// Result builder for authoring declarative prompt trees.
///
/// The builder lowers authored control flow into semantic composites such as
/// ``PromptConditional``, ``PromptForEach``, and ``PromptOptional`` while preserving the
/// concrete authored composite types wherever possible.
///
/// ```swift
/// let prompt = Prompt {
///     SystemPrompt("You are helpful.")
///
///     if includeHistory {
///         Group {
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
    /// Produces an empty section for blocks with no authored prompt content.
    public static func buildBlock() -> EmptySection {
        EmptySection()
    }

    /// Starts a builder block with its first authored component unchanged.
    public static func buildPartialBlock<Content: PromptComposite>(first content: Content) -> Content {
        content
    }

    /// Appends a later sibling as a typed sequence wrapper.
    public static func buildPartialBlock<Accumulated: PromptComposite, Next: PromptComposite>(
        accumulated: Accumulated,
        next: Next
    ) -> PromptSequence<Accumulated, Next> {
        PromptSequence(accumulated, next)
    }

    /// Preserves a single prompt composite expression without extra wrapping.
    public static func buildExpression<S: PromptComposite>(_ section: S) -> S {
        section
    }

    /// Wraps an explicit list of prompt composites for further builder composition.
    public static func buildExpression(_ sections: [any PromptComposite]) -> PromptGroup {
        PromptGroup(sections)
    }

    /// Lowers an optional branch into ``PromptOptional``.
    public static func buildOptional<Content: PromptComposite>(
        _ component: Content?
    ) -> PromptOptional<Content, EmptySection> {
        // Preserve the authored optional node even when the branch resolves to nil so
        // downstream prompt introspection can still see that an optional boundary existed.
        PromptOptional(primary: component)
    }

    /// Lowers the selected `if` branch into ``PromptConditional``.
    public static func buildEither<TrueContent: PromptComposite, FalseContent: PromptComposite>(
        first component: TrueContent
    ) -> PromptConditional<TrueContent, FalseContent> {
        PromptConditional(first: component)
    }

    /// Lowers the selected `else` branch into ``PromptConditional``.
    public static func buildEither<TrueContent: PromptComposite, FalseContent: PromptComposite>(
        second component: FalseContent
    ) -> PromptConditional<TrueContent, FalseContent> {
        PromptConditional(second: component)
    }

    /// Lowers repeated builder output into ``PromptForEach``.
    public static func buildArray<Content: PromptComposite>(_ components: [Content]) -> PromptForEach<Content> {
        // Keep the loop as a first-class composite instead of flattening immediately so
        // later phases can distinguish authored repetition from ordinary sibling sections.
        PromptForEach(components)
    }

    /// Ignores expressions that produce no prompt content.
    public static func buildExpression(_: Void) -> EmptySection {
        EmptySection()
    }

    /// Returns the fully lowered root prompt content.
    public static func buildFinalResult<Content: PromptComposite>(_ component: Content) -> Content {
        component
    }
}
