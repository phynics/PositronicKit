import Foundation
import PKShared

/// Base protocol for prompt sections. Composite sections usually resolve by delegating to `body`.
public protocol Prompt: Sendable {
    associatedtype Body: Prompt = NeverSection
    var body: Body { get }
    var sectionPathComponent: String? { get }
    func resolve(in context: PromptResolutionContext) -> [ConcretePromptSection]
}

public extension Prompt {
    /// By default, composite sections contribute their type name to the resolution path.
    var sectionPathComponent: String? {
        String(describing: Self.self)
    }

    /// Default resolution walks into the section's `body` with an updated path context.
    func resolve(in context: PromptResolutionContext = PromptResolutionContext()) -> [ConcretePromptSection] {
        body.resolve(in: context.descending(into: sectionPathComponent))
    }
    
    /// Renders this composite prompt into its canonical plain-text representation.
    ///
    /// This convenience API assembles the prompt first so ordering and validation match
    /// ``assembledPrompt()``.
    func render() async -> String? {
        let rendered = try! await assembledPrompt().rendered().string
        return rendered.isEmpty ? nil : rendered
    }
    
    /// Resolves this declarative prompt tree into concrete prompt sections.
    func sections() -> [ConcretePromptSection] {
        resolve(in: PromptResolutionContext())
    }

    /// Assembles this declarative prompt tree into a validated, ordered prompt artifact.
    ///
    /// - Throws: ``AssembledPrompt/ValidationError`` when the concrete section graph is invalid.
    func assembledPrompt() throws -> AssembledPrompt {
        try AssembledPrompt(sections: sections())
    }
}
