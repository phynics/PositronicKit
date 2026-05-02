import Foundation

/// Structural wrapper for optional prompt content produced by ``PromptBuilder``.
public struct OptionalPrompt<Content: Prompt>: Prompt {
    package let content: Content?

    public init(_ content: Content?) {
        self.content = content
    }

    public var body: EmptyPrompt {
        EmptyPrompt()
    }

    public func makePromptNode() -> PromptNode? {
        content?.makePromptNode()
    }
}

/// Structural wrapper for conditional prompt branches produced by ``PromptBuilder``.
public struct EitherPrompt<First: Prompt, Second: Prompt>: Prompt {
    package enum Storage {
        case first(First)
        case second(Second)
    }

    package let storage: Storage

    package init(first: First) {
        self.storage = .first(first)
    }

    package init(second: Second) {
        self.storage = .second(second)
    }

    public var body: EmptyPrompt {
        EmptyPrompt()
    }

    public func makePromptNode() -> PromptNode? {
        switch storage {
        case let .first(prompt):
            prompt.makePromptNode()
        case let .second(prompt):
            prompt.makePromptNode()
        }
    }
}
