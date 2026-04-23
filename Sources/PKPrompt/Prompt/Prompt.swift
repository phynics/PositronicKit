import Foundation
import PKShared

/// Base protocol for declarative prompt composition.
public protocol Prompt: Sendable {
    associatedtype Body: Prompt = EmptyPrompt
    var body: Body { get }
}

package protocol PromptNodeConvertible: Prompt {
    func makePromptNode() -> PromptNode?
}

public extension Prompt {
    /// Renders this prompt into its canonical plain-text representation.
    func render() async -> String? {
        guard let rendered = try? await assemblePrompt().render().string else {
            return nil
        }
        return rendered.isEmpty ? nil : rendered
    }

    /// Assembles this declarative prompt tree into a validated, ordered prompt artifact.
    ///
    /// - Throws: ``PromptValidationError`` when the concrete section graph is invalid.
    func assemblePrompt() throws -> AssembledPrompt {
        try AssembledPrompt(sections: promptSections())
    }
}

package extension Prompt {
    func promptSections() -> [PromptSection] {
        PromptAssembly.resolve(self)
    }
}
