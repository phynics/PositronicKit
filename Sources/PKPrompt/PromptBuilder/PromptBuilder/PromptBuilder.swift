import Foundation

/// Result builder for authoring declarative prompt trees.
///
/// The builder normalizes authored syntax into structural ``Prompt`` values that are lowered to
/// the internal prompt-node tree during prompt assembly. Ordinary sibling composition becomes
/// transparent groups, conditionals select the active branch, and plain `for` loops use
/// positional iteration path components.
///
/// Use ``PromptForEach`` or ``PromptBuilder/forEach(_:id:content:)`` when loop identity should
/// come from stable domain data instead of loop position.
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
    private static func normalize(_ prompt: some Prompt) -> AnyPrompt {
        if let prompt = prompt as? AnyPrompt {
            return prompt
        }
        return AnyPrompt([prompt])
    }

    private static func flatten(_ content: [AnyPrompt]) -> [any Prompt] {
        content.flatMap(\.prompts)
    }

    public static func buildBlock(_ content: AnyPrompt) -> AnyPrompt {
        content
    }

    /// Wraps authored siblings in a transparent node group.
    public static func buildBlock(_ content: AnyPrompt...) -> AnyPrompt {
        AnyPrompt(flatten(content))
    }

    /// Preserves a single prompt expression as structural prompt content.
    public static func buildExpression<S: Prompt>(_ section: S) -> AnyPrompt {
        normalize(section)
    }

    /// Wraps an explicit list of prompt composites in a transparent node group.
    public static func buildExpression(_ sections: [any Prompt]) -> AnyPrompt {
        AnyPrompt(sections)
    }

    /// Omits missing optional branches.
    public static func buildOptional(_ component: AnyPrompt?) -> AnyPrompt {
        component ?? AnyPrompt()
    }

    /// Preserves the selected `if` branch.
    public static func buildEither(first component: AnyPrompt) -> AnyPrompt {
        component
    }

    /// Preserves the selected `else` branch.
    public static func buildEither(second component: AnyPrompt) -> AnyPrompt {
        component
    }

    /// Lowers repeated builder output into positional per-item path groups.
    public static func buildArray(_ components: [AnyPrompt]) -> AnyPrompt {
        AnyPrompt([
            PromptForEach<AnyPrompt>(
                children: components,
                iterationPathComponents: components.indices.map { "item_\($0)" }
            )
        ])
    }

    /// Ignores expressions that produce no prompt content.
    public static func buildExpression(_: Void) -> AnyPrompt {
        AnyPrompt()
    }

    /// Returns the fully lowered root prompt content.
    public static func buildFinalResult(_ component: AnyPrompt) -> some Prompt {
        component
    }

    /// Convenience entry point for stable loop identity inside prompt builder call sites.
    public static func forEach<Data, Content>(
        _ data: Data,
        @PromptBuilder content: (Data.Element) -> Content
    ) -> PromptForEach<Content>
    where Data: RandomAccessCollection, Data.Element: Identifiable, Content: Prompt {
        PromptForEach(data, content: content)
    }

    /// Convenience entry point for stable loop identity keyed by a source property.
    public static func forEach<Data, ID, Content>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @PromptBuilder content: (Data.Element) -> Content
    ) -> PromptForEach<Content>
    where Data: RandomAccessCollection, Content: Prompt {
        PromptForEach(data, id: id, content: content)
    }

    /// Convenience entry point for stable loop identity derived from a closure.
    public static func forEach<Data, Content>(
        _ data: Data,
        id: (Data.Element) -> String,
        @PromptBuilder content: (Data.Element) -> Content
    ) -> PromptForEach<Content>
    where Data: RandomAccessCollection, Content: Prompt {
        PromptForEach(data, id: id, content: content)
    }
}
