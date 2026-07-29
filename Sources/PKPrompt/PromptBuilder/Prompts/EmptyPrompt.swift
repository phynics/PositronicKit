import Foundation

/// A prompt that renders to nothing. Used as the terminal `body` for prompt primitives and
/// as an explicit no-op branch in conditional prompt-building logic; `makePromptNode()`
/// returns `nil` so it contributes no node to the assembled prompt tree.
public struct EmptyPrompt: Prompt {
    public init() {}
    public var body: EmptyPrompt {
        self
    }

    public func makePromptNode() -> PromptNode? {
        nil
    }
}
