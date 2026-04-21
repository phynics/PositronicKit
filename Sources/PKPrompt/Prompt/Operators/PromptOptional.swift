import Foundation
import PKShared

/// A wrapper that resolves optional prompt content, with an optional fallback branch.
///
/// ``PromptBuilder`` lowers optional branches into this composite so the prompt tree keeps
/// track of the authored optional shape while still resolving transparently at assembly time.
public struct PromptOptional<Primary: Prompt, Fallback: Prompt>: Prompt {
    /// The preferred prompt content when available.
    public let primary: Primary?
    /// The fallback prompt content when the primary branch is absent.
    public let fallback: Fallback?

    /// Creates an optional prompt wrapper.
    ///
    /// - Parameters:
    ///   - primary: The preferred prompt content.
    ///   - fallback: Fallback content when the primary branch is absent.
    public init(primary: Primary?, fallback: Fallback? = nil) {
        self.primary = primary
        self.fallback = fallback
    }

    /// A placeholder body because this composite resolves through its stored branches directly.
    public var body: NeverSection {
        NeverSection()
    }

    /// Optional wrappers are transparent during path construction.
    public var sectionPathComponent: String? {
        nil
    }

    /// Resolves the primary branch when present, otherwise the fallback branch.
    ///
    /// - Parameter context: The resolution context to pass into the chosen branch.
    /// - Returns: The resolved output of the chosen branch, or an empty array if neither exists.
    public func resolve(in context: PromptResolutionContext) -> [ResolvedPromptSection] {
        if let primary {
            return primary.resolve(in: context)
        }
        return fallback?.resolve(in: context) ?? []
    }
}
