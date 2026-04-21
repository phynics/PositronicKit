import Foundation
import PKShared

/// A transparent root container for prompt sections that resolves to the concatenated output of its children.
public struct AnyPrompt: Prompt {
    /// The prompt values contained in the root container.
    public let prompts: [any Prompt]

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

    /// The path component for this root prompt container.
    ///
    /// Root prompt containers are transparent during path construction, so this value is always `nil`.
    public var sectionPathComponent: String? {
        nil
    }

    /// Resolves each contained section and returns their combined resolved output.
    ///
    /// - Parameter context: The resolution context to use for each child section.
    /// - Returns: The concatenated concrete sections produced by the group's children.
    public func resolveSections(in context: PromptResolutionContext) -> [ConcretePromptSection] {
        prompts.flatMap { $0.resolveSections(in: context) }
    }

    /// Preferred root entry point for prompt builder content.
    ///
    /// Use this when you want a named top-level builder API such as `AnyPrompt.build { ... }`.
    public static func build<Content: Prompt>(@PromptBuilder _ content: () -> Content) -> AnyPrompt {
        AnyPrompt(content)
    }
}
