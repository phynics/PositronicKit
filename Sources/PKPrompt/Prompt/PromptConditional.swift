import Foundation
import PKShared

/// A semantic wrapper for a conditionally selected prompt branch.
///
/// ``PromptBuilder`` lowers `if` / `else` branches into this composite so the authored
/// prompt tree retains the fact that a branch was selected, even though resolution is
/// transparent to downstream assembly.
public struct PromptConditional: PromptComposite {
    /// The selected branch content.
    public let content: any PromptComposite

    /// Creates a conditional wrapper around the selected branch.
    ///
    /// - Parameter content: The prompt content selected by a conditional branch.
    public init(_ content: any PromptComposite) {
        self.content = content
    }

    /// A placeholder body because this composite resolves through ``content`` directly.
    public var body: NeverSection {
        NeverSection()
    }

    /// Conditional wrappers are transparent during path construction.
    public var sectionPathComponent: String? {
        nil
    }

    /// Resolves the selected conditional branch.
    ///
    /// - Parameter context: The resolution context to pass into the selected branch.
    /// - Returns: The resolved output of the selected branch.
    public func resolve(in context: PromptResolutionContext) -> [ResolvedPromptSection] {
        content.resolve(in: context)
    }
}
