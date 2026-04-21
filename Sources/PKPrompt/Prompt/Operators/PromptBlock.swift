import Foundation
import PKShared

/// A lightweight typed wrapper for sibling prompt content authored in a builder block.
public struct PromptBlock<each Content: Prompt>: Prompt {
    /// The children in source order.
    public let content: (repeat each Content)

    /// Creates a typed block wrapper for sibling prompt composites.
    public init(_ content: repeat each Content) {
        self.content = (repeat each content)
    }

    /// A placeholder body because blocks resolve through their stored children directly.
    public var body: EmptySection {
        EmptySection()
    }

    /// Blocks are transparent during path construction.
    public var sectionPathComponent: String? {
        nil
    }

    /// Resolves each child in source order.
    public func resolveSections(in context: PromptResolutionContext) -> [ConcretePromptSection] {
        var resolvedSections: [ConcretePromptSection] = []
        repeat resolvedSections += (each content).resolveSections(in: context)
        return resolvedSections
    }
}
