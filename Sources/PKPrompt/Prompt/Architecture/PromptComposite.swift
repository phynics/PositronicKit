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

    /// Renders this composite by assembling it into an ordered prompt artifact first.
    func render() async -> String? {
        let rendered = await assembledPrompt().buildString()
        return rendered.isEmpty ? nil : rendered
    }

    /// Resolves this declarative prompt tree into concrete prompt sections.
    func resolvedSections() -> [ResolvedPromptSection] {
        resolve(in: PromptResolutionContext())
    }

    /// Assembles this declarative prompt tree into an ordered prompt artifact.
    func assembledPrompt() -> AssembledPrompt {
        try! AssembledPrompt(resolvedSections: resolvedSections())
    }
}
