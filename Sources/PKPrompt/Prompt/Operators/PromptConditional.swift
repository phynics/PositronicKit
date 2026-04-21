import Foundation
import PKShared

/// A semantic wrapper for a conditionally selected prompt branch.
///
/// ``PromptBuilder`` lowers `if` / `else` branches into this composite so the authored
/// prompt tree retains the fact that a branch was selected, even though resolution is
/// transparent to downstream assembly.
public struct PromptConditional<First: Prompt, Second: Prompt>: Prompt {
    /// The selected branch content.
    public let storage: Storage

    /// Typed storage for the selected branch.
    public enum Storage: Sendable {
        case first(First)
        case second(Second)
    }

    /// Creates a conditional wrapper around the selected branch.
    ///
    /// - Parameter content: The prompt content selected by a conditional branch.
    public init(first content: First) {
        self.storage = .first(content)
    }

    /// Creates a conditional wrapper around the selected fallback branch.
    ///
    /// - Parameter content: The prompt content selected by the alternate branch.
    public init(second content: Second) {
        self.storage = .second(content)
    }

    /// A placeholder body because this composite resolves through its stored branch directly.
    public var body: EmptySection {
        EmptySection()
    }

    /// Conditional wrappers are transparent during path construction.
    public var sectionPathComponent: String? {
        nil
    }

    /// Resolves the selected conditional branch.
    ///
    /// - Parameter context: The resolution context to pass into the selected branch.
    /// - Returns: The resolved output of the selected branch.
    public func resolveSections(in context: PromptResolutionContext) -> [ConcretePromptSection] {
        switch storage {
        case let .first(content):
            return content.resolveSections(in: context)
        case let .second(content):
            return content.resolveSections(in: context)
        }
    }
}
