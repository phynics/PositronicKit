import Foundation
import PKContracts
import PKUtilities

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
    package var compression: CompressionStrategy { .truncate(keeping: .tail) }
    package var type: PromptSectionType { .list }

    package var estimatedTokens: Int {
        TokenEstimator.estimate(parts: messages.map(\.content))
    }

    package var content: PromptPrimitiveContent { .messages(messages) }
    package func renderContent() async -> String? { nil }
}
