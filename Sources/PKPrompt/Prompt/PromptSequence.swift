import Foundation
import PKShared

/// A lightweight typed wrapper for sibling prompt content authored in a builder block.
public struct PromptSequence<First: PromptComposite, Second: PromptComposite>: PromptComposite {
    /// The first child in source order.
    public let first: First
    /// The second child, which may itself be another ``PromptSequence``.
    public let second: Second

    /// Creates a typed sequence wrapper for two sibling prompt composites.
    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }

    /// A placeholder body because sequences resolve through their stored children directly.
    public var body: NeverSection {
        NeverSection()
    }

    /// Sequences are transparent during path construction.
    public var sectionPathComponent: String? {
        nil
    }

    /// Resolves both children in source order.
    public func resolve(in context: PromptResolutionContext) -> [ResolvedPromptSection] {
        first.resolve(in: context) + second.resolve(in: context)
    }
}
