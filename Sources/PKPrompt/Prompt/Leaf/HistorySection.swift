import Foundation
import PKShared

public struct HistorySection: PromptLeaf {
    public let id: String
    public let messages: [Message]
    public let priority: Int
    public let cachePolicy: CachePolicy

    public init(
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

    public var role: PromptSectionRole {
        .chatHistory
    }

    public var compression: CompressionStrategy {
        .truncate(tail: false)
    }

    public var type: PromptSectionType {
        .list
    }

    public var estimatedTokens: Int {
        max(1, messages.reduce(into: 0) { partialResult, message in
            partialResult += estimatedTokenCount(for: message.content)
        })
    }

    public var content: PromptLeafContent {
        .messages(messages)
    }

    public func renderContent() async -> String? {
        nil
    }
}
