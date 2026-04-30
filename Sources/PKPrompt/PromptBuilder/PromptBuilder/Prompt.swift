import Foundation
import PKShared

/// Base protocol for declarative prompt composition.
public protocol Prompt: Sendable {
    associatedtype Body: Prompt
    var body: Body { get }
    func makePromptNode() -> PromptNode?
}

public extension Prompt {
    func makePromptNode() -> PromptNode? {
        guard let bodyNode = self.body.makeNode() else {
            return nil
        }

        return PromptNode(
            pathComponent: promptPathComponent(for: self),
            .fork([bodyNode])
        )
    }

    /// Assembles this declarative prompt tree into a validated, ordered prompt artifact.
    ///
    /// - Throws: ``AssembledPrompt/ValidationError`` when the concrete section graph is invalid.
    func assemblePrompt() throws -> AssembledPrompt {
        try AssembledPrompt(sections: resolveSections(in: .init()))
    }

    /// Renders this prompt into its canonical plain-text representation.
    func renderToString() async -> String? {
        guard let rendered = try? await assemblePrompt().render().string else {
            return nil
        }
        return rendered.isEmpty ? nil : rendered
    }
}

// MARK: Path helpers

private func promptPathComponent<P: Prompt>(for prompt: P) -> String {
    let typeName = String(describing: type(of: prompt))
    guard let prompt = prompt as? any Identifiable else {
        return typeName
    }
    return "\(typeName) \(prompt.id.hashValue)"
}
