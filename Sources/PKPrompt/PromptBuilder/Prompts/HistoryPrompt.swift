import Foundation
import PKShared

public struct HistoryPrompt: Prompt {
    public let id: String
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
