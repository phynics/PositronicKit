import Foundation
import PKShared

public struct EmptyPrompt: Prompt {
    public init() {}
    public var body: EmptyPrompt { self }
}

/// Semantic alias for a section that intentionally resolves to no output.
public typealias EmptySection = EmptyPrompt
