import Foundation
import PKShared

/// A transparent wrapper for repeated prompt content generated from a loop.
///
/// ``PromptBuilder`` lowers `for` loops into this composite so repeated authoring intent
/// remains explicit in the prompt tree before final resolution.
public struct PromptForEach<Content: PromptComposite>: PromptComposite {
    /// The repeated prompt content instances produced by the loop.
    public let content: [Content]

    /// Creates a wrapper for repeated prompt content.
    ///
    /// - Parameter content: The prompt content instances produced by iteration.
    public init(_ content: [Content]) {
        self.content = content
    }

    /// A placeholder body because this composite resolves through ``content`` directly.
    public var body: NeverSection {
        NeverSection()
    }

    /// Loop wrappers are transparent during path construction.
    public var sectionPathComponent: String? {
        nil
    }

    /// Resolves each repeated child in iteration order.
    ///
    /// - Parameter context: The resolution context to pass to each repeated child.
    /// - Returns: The concatenated resolved output of all repeated children.
    public func resolve(in context: PromptResolutionContext) -> [ResolvedPromptSection] {
        content.flatMap { $0.resolve(in: context) }
    }
}
