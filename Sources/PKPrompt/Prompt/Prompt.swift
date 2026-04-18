import Foundation

/// Lightweight wrapper for a declarative prompt definition.
public struct Prompt: Sendable {
    public let sections: [any PromptComposite]

    public init(sections: [any PromptComposite]) {
        try? validateUniqueSectionIDs(sections)
        self.sections = sections
    }

    public init(@PromptBuilder _ content: () -> some PromptComposite) {
        self.init(sections: [content()])
    }

    public func assemble() -> AssembledPrompt {
        AssembledPrompt(
            resolvedSections: sections.flatMap { $0.resolve(in: PromptResolutionContext()) }
        )
    }
}
