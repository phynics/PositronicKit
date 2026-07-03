import Foundation

/// Explicit loop helper for prompt sections built from a homogeneous data array.
///
/// `ForEach` wraps a `[Data]` array and a content closure, lowering each element's
/// `Prompt` into a `.fork` node. It does **not** attach positional path components
/// to the children — each child's path is whatever its own `id` (or structural
/// identity) produces. Loop-item uniqueness is the caller's responsibility: two
/// items whose prompts resolve to the same section id will collide at assembly
/// time and raise `PromptAssemblyError.duplicateSectionIDs`.
///
/// ```swift
/// ForEach(workspaces) { workspace in
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
