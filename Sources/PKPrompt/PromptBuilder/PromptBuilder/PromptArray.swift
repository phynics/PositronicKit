import Foundation

/// Structural wrapper for homogeneous prompt arrays authored inside ``PromptBuilder``.
public struct PromptArray<Content: Prompt>: Prompt {
    package let prompts: [Content]

    public init(_ prompts: [Content]) {
        self.prompts = prompts
    }

    public var body: EmptyPrompt {
        EmptyPrompt()
    }

    public func makePromptNode() -> PromptNode? {
        let children = prompts.compactMap { $0.makePromptNode() }
        if children.count == 1 {
            return children[0]
        }
        return children.isEmpty ? nil : PromptNode(.fork(children))
    }
}
