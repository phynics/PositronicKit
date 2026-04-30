import Foundation
import PKShared

/// Base protocol for declarative prompt composition.
public protocol Prompt: Sendable {
    associatedtype Body: Prompt
    var body: Body { get }
}

package protocol PromptNodeConvertible: Prompt {
    func makePromptNode() -> PromptNode?
}

public extension Prompt {
    /// Assembles this declarative prompt tree into a validated, ordered prompt artifact.
    ///
    /// - Throws: ``AssembledPrompt/ValidationError`` when the concrete section graph is invalid.
    func assemblePrompt() throws -> AssembledPrompt {
        try AssembledPrompt(sections: resolveSections())
    }
    
    /// Renders this prompt into its canonical plain-text representation.
    func renderToString() async -> String? {
        guard let rendered = try? await assemblePrompt().render().string else {
            return nil
        }
        return rendered.isEmpty ? nil : rendered
    }
}
