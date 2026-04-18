import Foundation
import PKShared

/// Base protocol for prompt sections. Composite sections usually resolve by delegating to `body`.
public protocol PromptComposite: Sendable {
    associatedtype Body: PromptComposite = NeverSection
    var body: Body { get }
    var sectionPathComponent: String? { get }
    func resolve(in context: PromptResolutionContext) -> [ResolvedPromptSection]
}

public extension PromptComposite {
    /// By default, composite sections contribute their type name to the resolution path.
    var sectionPathComponent: String? {
        String(describing: Self.self)
    }

    /// Default resolution walks into the section's `body` with an updated path context.
    func resolve(in context: PromptResolutionContext = PromptResolutionContext()) -> [ResolvedPromptSection] {
        body.resolve(in: context.descending(into: sectionPathComponent))
    }

    /// Renders the first resolved section produced by this composite.
    func render() async -> String? {
        await resolve(in: PromptResolutionContext()).first?.render()
    }

    /// Renders the first resolved section produced by this composite using an optional token limit.
    func render(constrainedTo tokens: Int?) async -> String? {
        await resolve(in: PromptResolutionContext()).first?.render(constrainedTo: tokens)
    }

}
