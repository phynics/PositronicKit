import Foundation
import PKShared

package struct HistoryPromptPrimitive: PromptPrimitive {
    package let id: String
    package let messages: [Message]
    package let priority: Int
    package let cachePolicy: CachePolicy

    package init(
        id: String = "chat_history",
        messages: [Message],
        priority: Int = 70,
        cachePolicy: CachePolicy = .volatile
    ) {
        self.id = id
        self.messages = messages
        self.priority = priority
        self.cachePolicy = cachePolicy
    }

    package var role: PromptSectionRole { .chatHistory }
    package var compression: CompressionStrategy { .truncate(tail: false) }
    package var type: PromptSectionType { .list }

    package var estimatedTokens: Int {
        max(1, messages.reduce(into: 0) { partialResult, message in
            partialResult += message.content.estimatedTokenCount
        })
    }

    package var content: PromptPrimitiveContent { .messages(messages) }
    package func renderContent() async -> String? { nil }
}
