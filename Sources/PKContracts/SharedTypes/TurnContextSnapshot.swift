import Foundation

/// A serializable representation of the context assembled for a turn.
///
/// Mirrors the prompt messages used for a turn without exposing internal runtime types.
public struct TurnContextSnapshot: Sendable, Codable, Equatable {
    /// The assembled prompt messages sent to the LLM, in order.
    public let promptMessages: [PromptMessage]

    public init(
        promptMessages: [PromptMessage] = []
    ) {
        self.promptMessages = promptMessages
    }

    /// A serialized prompt message sent to the LLM.
    public struct PromptMessage: Sendable, Codable, Equatable {
        public let role: String
        public let content: String
        /// Estimated token count for this message.
        public let tokenCount: Int

        public init(role: String, content: String, tokenCount: Int = 0) {
            self.role = role
            self.content = content
            self.tokenCount = tokenCount
        }
    }

}
