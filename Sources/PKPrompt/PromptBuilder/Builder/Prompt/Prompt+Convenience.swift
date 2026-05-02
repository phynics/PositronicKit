import Foundation
import PKShared

public extension Prompt {
    func priority(_ value: Int) -> some Prompt {
        PromptModifiers.Priority(content: self, priority: value)
    }

    func priority(_ value: PromptPriority) -> some Prompt {
        PromptModifiers.Priority(content: self, priority: value.rawValue)
    }

    func compression(_ value: CompressionStrategy) -> some Prompt {
        PromptModifiers.Compression(content: self, compression: value)
    }

    func cachePolicy(_ value: CachePolicy) -> some Prompt {
        PromptModifiers.CachePolicy(content: self, cachePolicy: value)
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
