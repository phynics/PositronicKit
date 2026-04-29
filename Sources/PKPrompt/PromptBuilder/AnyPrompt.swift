import Foundation
import PKShared

/// A transparent root container for prompt sections that resolves to the concatenated output of its children.
public struct AnyPrompt: Prompt, PromptNodeConvertible {
    /// The prompt values contained in the root container.
    package let prompts: [any Prompt]

    /// Creates a root container from an array of sections.
    ///
    /// - Parameter sections: The sections to include in the group.
    public init(_ sections: [any Prompt] = []) {
        self.prompts = sections
    }

    /// Creates a root container from a ``PromptBuilder`` closure.
    ///
    /// - Parameter content: A builder that produces the section content for the container.
    public init(@PromptBuilder _ content: () -> some Prompt) {
        self.prompts = [content()]
    }

    /// A placeholder body because ``AnyPrompt`` resolves through its contained sections directly.
    public var body: EmptyPrompt {
        EmptyPrompt()
    }

    package func makePromptNode() -> PromptNode? {
        let children = prompts.compactMap { PromptAssembly.makeNode(from: $0) }
        if children.count == 1 {
            return children[0]
        }
        return children.isEmpty ? nil : PromptNode(.fork(children))
    }

    /// Preferred root entry point for prompt builder content.
    ///
    /// Use this when you want a named top-level builder API such as `AnyPrompt.build { ... }`.
    public static func build<Content: Prompt>(@PromptBuilder _ content: () -> Content) -> AnyPrompt {
        AnyPrompt(content)
    }
}
