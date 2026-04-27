import Foundation

/// Result builder for authoring declarative prompt trees.
///
/// The builder lowers authored syntax directly into the internal prompt-node tree used by prompt
/// assembly. Ordinary sibling composition becomes transparent groups, conditionals select the
/// active branch, and plain `for` loops use positional iteration path components.
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
    public struct Partial: Prompt, PromptNodeConvertible {
        package let node: PromptNode?

        package init(node: PromptNode?) {
            self.node = node
        }

        public var body: EmptyPrompt { EmptyPrompt() }

        package func makePromptNode() -> PromptNode? {
            node
        }
    }

    public static func buildBlock(_ content: Partial) -> Partial {
        content
    }

    /// Wraps authored siblings in a transparent node group.
    public static func buildBlock(_ content: Partial...) -> Partial {
        Partial(node: PromptNode.group(children: content.compactMap(\.node)))
    }

    /// Preserves a single prompt expression by lowering it to a prompt node immediately.
    public static func buildExpression<S: Prompt>(_ section: S) -> Partial {
        Partial(node: PromptAssembly.makeNode(from: section))
    }

    /// Wraps an explicit list of prompt composites in a transparent node group.
    public static func buildExpression(_ sections: [any Prompt]) -> Partial {
        Partial(node: PromptNode.group(children: sections.compactMap { PromptAssembly.makeNode(from: $0) }))
    }

    /// Omits missing optional branches.
    public static func buildOptional(_ component: Partial?) -> Partial {
        component ?? Partial(node: nil)
    }

    /// Preserves the selected `if` branch.
    public static func buildEither(first component: Partial) -> Partial {
        component
    }

    /// Preserves the selected `else` branch.
    public static func buildEither(second component: Partial) -> Partial {
        component
    }

    /// Lowers repeated builder output into positional per-item path groups.
    public static func buildArray(_ components: [Partial]) -> Partial {
        Partial(node: PromptNode.group(children: components.enumerated().compactMap { index, component in
            guard let node = component.node else { return nil }
            return PromptNode.group(pathComponent: "item_\(index)", children: [node])
        }))
    }

    /// Ignores expressions that produce no prompt content.
    public static func buildExpression(_: Void) -> Partial {
        Partial(node: nil)
    }

    /// Returns the fully lowered root prompt content.
    public static func buildFinalResult(_ component: Partial) -> some Prompt {
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
