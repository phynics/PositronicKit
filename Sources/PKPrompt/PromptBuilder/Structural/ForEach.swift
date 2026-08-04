import Foundation

/// Explicit loop helper for prompt sections built from a homogeneous data array.
///
/// `ForEach` wraps an element array and a content closure, lowering each element's
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
    package let elements: [Data]
    package let content: @Sendable (_ element: Data) -> Content

    /// Creates a prompt loop over `elements`.
    public init(
        _ elements: [Data],
        @PromptBuilder content: @Sendable @escaping (_ element: Data) -> Content
    ) {
        self.elements = elements
        self.content = content
    }

    /// Creates a prompt loop using the legacy `data` label.
    @available(*, deprecated, message: "Use init(_:content:).")
    public init(
        data: [Data],
        @PromptBuilder content: @Sendable @escaping (_ element: Data) -> Content
    ) {
        self.init(data, content: content)
    }

    public var body: EmptyPrompt { EmptyPrompt() }

    public func makePromptNode() -> PromptNode? {
        let nodes: [PromptNode] = elements.compactMap {
            content($0).makePromptNode()
        }

        guard !nodes.isEmpty else {
            return nil
        }

        return PromptNode(.fork(nodes))
    }
}
