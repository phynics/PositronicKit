import Foundation
import PKShared

/// A transparent grouping of prompt sections that resolves to the concatenated output of its children.
public struct PromptGroup: PromptComposite {
    /// The sections contained in the group.
    public let sections: [any PromptComposite]

    /// Creates a group from an array of sections.
    ///
    /// - Parameter sections: The sections to include in the group.
    public init(_ sections: [any PromptComposite] = []) {
        self.sections = sections
    }

    /// Creates a group from a ``ContextBuilder`` closure.
    ///
    /// - Parameter content: A builder that produces the section content for the group.
    public init(@ContextBuilder _ content: () -> some PromptComposite) {
        self.sections = [content()]
    }

    /// A placeholder body because ``PromptGroup`` resolves through its contained sections directly.
    public var body: NeverSection {
        NeverSection()
    }

    /// The path component for this prompt group.
    ///
    /// Prompt groups are transparent during path construction, so this value is always `nil`.
    public var sectionPathComponent: String? {
        nil
    }

    /// Resolves each contained section and returns their combined resolved output.
    ///
    /// - Parameter context: The resolution context to use for each child section.
    /// - Returns: The concatenated resolved sections produced by the group's children.
    public func resolve(in context: PromptResolutionContext) -> [ResolvedPromptSection] {
        sections.flatMap { $0.resolve(in: context) }
    }
}
