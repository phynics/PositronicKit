import Foundation
import PKShared

public struct EmptyPrompt: Prompt {
    public init() {}
    public var body: EmptyPrompt { self }

    public func makePromptNode() -> PromptNode? {
        nil
    }
}

/// Semantic alias for a section that intentionally resolves to no output.
public typealias EmptySection = EmptyPrompt
