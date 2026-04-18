import Foundation

/// Result builder for authoring declarative prompt trees.
///
/// The builder lowers authored control flow into semantic composites such as
/// ``PromptConditional``, ``PromptForEach``, and ``PromptOptionalFallback`` while using
/// ``PromptGroup`` as the concrete aggregation node passed between builder stages.
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
    /// Combines sibling builder components into a single transparent group.
    public static func buildBlock(_ components: PromptGroup...) -> PromptGroup {
        PromptGroup(components.flatMap(\.sections))
    }

    /// Wraps a single prompt composite expression for further builder composition.
    public static func buildExpression<S: PromptComposite>(_ section: S) -> PromptGroup {
        PromptGroup([section])
    }

    /// Wraps an explicit list of prompt composites for further builder composition.
    public static func buildExpression(_ sections: [any PromptComposite]) -> PromptGroup {
        PromptGroup(sections)
    }

    /// Lowers an optional branch into ``PromptOptionalFallback``.
    public static func buildOptional(_ component: PromptGroup?) -> PromptGroup {
        // Preserve the authored optional node even when the branch resolves to nil so
        // downstream prompt introspection can still see that an optional boundary existed.
        PromptGroup([PromptOptionalFallback(primary: component)])
    }

    /// Lowers the selected `if` branch into ``PromptConditional``.
    public static func buildEither(first component: PromptGroup) -> PromptGroup {
        PromptGroup([PromptConditional(component)])
    }

    /// Lowers the selected `else` branch into ``PromptConditional``.
    public static func buildEither(second component: PromptGroup) -> PromptGroup {
        PromptGroup([PromptConditional(component)])
    }

    /// Lowers repeated builder output into ``PromptForEach``.
    public static func buildArray(_ components: [PromptGroup]) -> PromptGroup {
        // Keep the loop as a first-class composite instead of flattening immediately so
        // later phases can distinguish authored repetition from ordinary sibling sections.
        PromptGroup([PromptForEach(components)])
    }

    /// Ignores expressions that produce no prompt content.
    public static func buildExpression(_: Void) -> PromptGroup {
        PromptGroup()
    }

    /// Returns the fully lowered root prompt group.
    public static func buildFinalResult(_ component: PromptGroup) -> PromptGroup {
        component
    }
}
