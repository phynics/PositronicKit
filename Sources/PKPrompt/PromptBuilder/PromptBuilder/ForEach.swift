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
public struct ForEach<Data: Sendable, Content: Prompt & Sendable>: Prompt {
    package let data: [Data]
    package let content: @Sendable (Data) -> Content

    public init(data: [Data], @PromptBuilder content: @Sendable @escaping (Data) -> Content) {
        self.data = data
        self.content = content
    }


    public var body: EmptyPrompt { EmptyPrompt() }

    public func makePromptNode() -> PromptNode? {
        let nodes: [PromptNode] = data.compactMap {
            content($0).makePromptNode()
        }
        
        guard !nodes.isEmpty else {
            return nil
        }
        
        return PromptNode(.fork(nodes))
    }
}
