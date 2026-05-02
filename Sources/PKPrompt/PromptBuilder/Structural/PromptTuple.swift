import Foundation
import PKShared

/// Variadic structural prompt container used by ``PromptBuilder`` sibling composition.
public struct PromptTuple<each Content: Prompt>: Prompt {
    package let prompts: (repeat each Content)

    public init(_ prompts: repeat each Content) {
        self.prompts = (repeat each prompts)
    }

    public var body: EmptyPrompt {
        EmptyPrompt()
    }

    public func makePromptNode() -> PromptNode? {
        var children: [PromptNode] = []

        for prompt in repeat each prompts {
            if let node = prompt.makePromptNode() {
                children.append(node)
            }
        }

        if children.count == 1 {
            return children[0]
        }
        return children.isEmpty ? nil : PromptNode(.fork(children))
    }
}
