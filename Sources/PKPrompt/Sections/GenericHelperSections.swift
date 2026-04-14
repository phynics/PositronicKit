import Foundation
import PKShared

public struct TextSection: PrimitiveContextSection {
    public let id: String
    public let text: String
    public let role: PromptSectionRole
    public let priority: Int
    public let compression: CompressionStrategy
    public let cachePolicy: CachePolicy
    private let estimatedTokenOverride: Int?

    public init(
        id: String,
        text: String,
        role: PromptSectionRole = .context,
        priority: Int = 50,
        compression: CompressionStrategy = .keep,
        cachePolicy: CachePolicy = .volatile,
        estimatedTokens: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.role = role
        self.priority = priority
        self.compression = compression
        self.cachePolicy = cachePolicy
        self.estimatedTokenOverride = estimatedTokens
    }

    public func renderContent() async -> String? {
        guard !text.isEmpty else { return nil }
        return text
    }

    public var estimatedTokens: Int {
        estimatedTokenOverride ?? estimatedTokenCount(for: text)
    }
}

public struct SystemPrompt: ContextSection {
    public let id: String
    public let text: String
    public let priority: Int
    public let compression: CompressionStrategy
    public let estimatedTokens: Int?

    public init(
        _ text: String,
        id: String = "system",
        priority: Int = PromptPriority.critical.rawValue,
        compression: CompressionStrategy = .keep,
        estimatedTokens: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.priority = priority
        self.compression = compression
        self.estimatedTokens = estimatedTokens
    }

    public var body: some ContextSection {
        TextSection(
            id: id,
            text: text,
            role: .system,
            priority: priority,
            compression: compression,
            cachePolicy: .stable,
            estimatedTokens: estimatedTokens
        )
    }
}

public struct ContextPrompt: ContextSection {
    public let id: String
    public let text: String
    public let priority: Int
    public let compression: CompressionStrategy
    public let cachePolicy: CachePolicy
    public let estimatedTokens: Int?

    public init(
        _ text: String,
        id: String,
        priority: Int = PromptPriority.medium.rawValue,
        compression: CompressionStrategy = .keep,
        cachePolicy: CachePolicy = .volatile,
        estimatedTokens: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.priority = priority
        self.compression = compression
        self.cachePolicy = cachePolicy
        self.estimatedTokens = estimatedTokens
    }

    public var body: some ContextSection {
        TextSection(
            id: id,
            text: text,
            role: .context,
            priority: priority,
            compression: compression,
            cachePolicy: cachePolicy,
            estimatedTokens: estimatedTokens
        )
    }
}

public struct UserPrompt: ContextSection {
    public let id: String
    public let text: String
    public let priority: Int
    public let estimatedTokens: Int?

    public init(
        _ text: String,
        id: String = "user_query",
        priority: Int = 10,
        estimatedTokens: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.priority = priority
        self.estimatedTokens = estimatedTokens
    }

    public var body: some ContextSection {
        TextSection(
            id: id,
            text: text,
            role: .userQuery,
            priority: priority,
            compression: .keep,
            cachePolicy: .volatile,
            estimatedTokens: estimatedTokens
        )
    }
}

public struct HistoryPrompt: ContextSection {
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

    public var body: some ContextSection {
        HistorySection(
            id: id,
            messages: messages,
            priority: priority,
            cachePolicy: cachePolicy
        )
    }
}

public struct HistorySection: PrimitiveContextSection {
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

    public var type: ContextSectionType {
        .list
    }

    public var estimatedTokens: Int {
        max(1, messages.reduce(into: 0) { partialResult, message in
            partialResult += estimatedTokenCount(for: message.content)
        })
    }

    public var historyMessages: [Message]? {
        messages
    }

    public func renderContent() async -> String? {
        nil
    }
}

private func estimatedTokenCount(for text: String) -> Int {
    text.isEmpty ? 0 : max(1, text.count / 4)
}
