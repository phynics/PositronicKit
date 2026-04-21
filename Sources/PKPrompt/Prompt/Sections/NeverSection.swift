import Foundation
import PKShared

public struct NeverSection: Prompt {
    public init() {}
    public var body: NeverSection { self }
    public var sectionPathComponent: String? { nil }
    public func resolve(in context: PromptResolutionContext) -> [ResolvedPromptSection] { [] }
}

/// Semantic alias for a section that intentionally resolves to no output.
public typealias EmptySection = NeverSection
