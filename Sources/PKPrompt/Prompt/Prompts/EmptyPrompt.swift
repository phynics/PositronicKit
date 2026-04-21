import Foundation
import PKShared

public struct EmptyPrompt: Prompt {
    public init() {}
    public var body: EmptyPrompt { self }
    public var sectionPathComponent: String? { nil }
    public func resolveSections(in context: PromptResolutionContext) -> [ConcretePromptSection] { [] }
}

/// Semantic alias for a section that intentionally resolves to no output.
public typealias EmptySection = EmptyPrompt
