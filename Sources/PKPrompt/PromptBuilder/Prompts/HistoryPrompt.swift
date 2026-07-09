import Foundation
import PKShared

/// The chat-history section in the ``PromptBuilder`` DSL, rendering prior conversation
/// `Message`s. Defaults to `role: .chatHistory`, `priority: 70`, and `cachePolicy: .volatile`.
public struct HistoryPrompt: Prompt {
    public let id: String
    /// The prior conversation messages to render into this section.
    public let messages: [Message]
    public let priority: Int
    public let cachePolicy: CachePolicy

    public init(
        _ messages: [Message],
        id: String = "chat_history",
        priority: Int = 70,
        cachePolicy: CachePolicy = .volatile
    ) {
        self.id = id
        self.messages = messages
        self.priority = priority
        self.cachePolicy = cachePolicy
    }

    public var body: some Prompt {
        HistoryPromptPrimitive(
            id: id,
            messages: messages,
            priority: priority,
            cachePolicy: cachePolicy
        )
    }
}
