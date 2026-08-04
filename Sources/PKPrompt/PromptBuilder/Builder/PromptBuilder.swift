import Foundation

/// Result builder for authoring declarative prompt trees.
///
/// The builder normalizes authored syntax into structural `Prompt` values that are lowered to
/// the internal prompt-node tree during prompt assembly. Ordinary sibling composition becomes
/// transparent groups, conditionals select the active branch, and plain `for` loops produce a
/// `ForEach` whose children carry their own section ids (no positional path disambiguation is
/// added — loop-item uniqueness is the caller's responsibility).
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
    // MARK: - Core

    public static func buildBlock<each Content>(_ content: repeat each Content) -> PromptTuple<repeat each Content>
    where repeat each Content: Prompt {
        PromptTuple<repeat each Content>(repeat each content)
    }

    /// Preserves a single prompt expression as structural prompt content.
    /// Prefer returning the concrete `S` to avoid type-erasure when possible.
    public static func buildExpression<S: Prompt>(_ section: S) -> S { section }

    /// Preserves homogeneous prompt arrays as structural prompt content.
    public static func buildExpression<S: Prompt>(_ sections: [S]) -> PromptArray<S> {
        PromptArray(sections)
    }

    /// Ignores expressions that produce no prompt content.
    public static func buildExpression(_: Void) -> EmptyPrompt { EmptyPrompt() }

    /// Returns the fully lowered root prompt content. Using `some Prompt` preserves structure.
    public static func buildFinalResult<T: Prompt>(_ component: T) -> T { component }

    // MARK: - Blocks (siblings)

    /// Single-item block passthrough. Keeps structural type.
    public static func buildBlock<T: Prompt>(_ content: T) -> T { content }

    // MARK: - Conditionals
    public static func buildOptional<Content: Prompt>(_ component: Content?) -> OptionalPrompt<Content> {
        OptionalPrompt(component)
    }

    /// Preserves the selected `if` branch.
    public static func buildEither<First: Prompt, Second: Prompt>(
        first component: First
    ) -> EitherPrompt<First, Second> {
        EitherPrompt(first: component)
    }

    /// Preserves the selected `else` branch.
    public static func buildEither<First: Prompt, Second: Prompt>(
        second component: Second
    ) -> EitherPrompt<First, Second> {
        EitherPrompt(second: component)
    }

    // MARK: - Arrays and loops

    /// Lowers repeated builder output into a `ForEach` whose children carry their own
    /// section ids. No positional path disambiguation is added — callers are responsible
    /// for ensuring loop-generated sections have unique ids.
    public static func buildArray<Content: Prompt & Sendable>(_ components: [Content]) -> ForEach<Int, Content> {
        ForEach((0..<components.count).map { Int($0) }) {
            components[$0]
        }
    }
}
