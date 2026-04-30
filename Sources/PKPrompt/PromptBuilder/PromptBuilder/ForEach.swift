import Foundation

/// Explicit loop helper for prompt sections that need stable structural identity.
///
/// Plain `for` loops inside ``PromptBuilder`` lower to positional path components such as
/// `item_0` and `item_1`. Use `PromptForEach` when the iteration identity should come from
/// domain data instead, which keeps node paths stable across reordering and improves diffing.
///
/// ```swift
/// PromptForEach(workspaces, id: \.id) { workspace in
///     TextPrompt(workspace.summary, id: "workspace-\(workspace.id)")
/// }
/// ```
public struct ForEach<Content: Prompt>: Prompt, PromptNodeConvertible {
    package let children: [AnyPrompt]
    package let iterationPathComponents: [String]

    package init(children: [AnyPrompt], iterationPathComponents: [String]) {
        self.children = children
        self.iterationPathComponents = iterationPathComponents
    }

    /// Creates a loop with positional iteration identity.
    public init<Data>(
        _ data: Data,
        @PromptBuilder content: (Data.Element) -> Content
    ) where Data: RandomAccessCollection {
        self.init(
            children: data.map { PromptBuilder.buildExpression(content($0)) },
            iterationPathComponents: data.indices.enumerated().map { offset, _ in "item_\(offset)" }
        )
    }

    /// Creates a loop whose iteration identity comes from a stable key path on the source data.
    public init<Data, ID>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @PromptBuilder content: (Data.Element) -> Content
    ) where Data: RandomAccessCollection {
        self.init(
            data,
            id: { String(describing: $0[keyPath: id]) },
            content: content
        )
    }

    /// Creates a loop whose iteration identity comes from a stable closure over the source data.
    ///
    /// Use this overload when the loop identity needs light transformation or when a key path is
    /// less readable than an inline expression.
    public init<Data>(
        _ data: Data,
        id: (Data.Element) -> String,
        @PromptBuilder content: (Data.Element) -> Content
    ) where Data: RandomAccessCollection {
        self.init(
            children: data.map { PromptBuilder.buildExpression(content($0)) },
            iterationPathComponents: data.map(id)
        )
    }

    /// Creates a loop whose iteration identity comes from the element's `Identifiable` id.
    public init<Data>(
        _ data: Data,
        @PromptBuilder content: (Data.Element) -> Content
    ) where Data: RandomAccessCollection, Data.Element: Identifiable {
        self.init(
            data,
            id: { String(describing: $0.id) },
            content: content
        )
    }

    public var body: EmptyPrompt { EmptyPrompt() }

    package func makePromptNode() -> PromptNode? {
        let nodes: [PromptNode] = zip(children, iterationPathComponents).compactMap { pair in
            let (child, pathComponent) = pair
            guard let node = child.makeNode() else {
                return nil
            }
            return PromptNode(pathComponent: pathComponent, .fork([node]))
        }

        return nodes.isEmpty ? nil : PromptNode(.fork(nodes))
    }
}
