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
        estimatedTokenOverride ?? (text.isEmpty ? 0 : max(1, text.count / 4))
    }
}

public struct SystemPrompt: PrimitiveContextSection {
    public let id: String
    public let text: String
    public let priority: Int
    public let compression: CompressionStrategy
    private let estimatedTokenOverride: Int?

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
        self.estimatedTokenOverride = estimatedTokens
    }

    public var role: PromptSectionRole {
        .system
    }

    public var cachePolicy: CachePolicy {
        .stable
    }

    public var estimatedTokens: Int {
        estimatedTokenOverride ?? (text.isEmpty ? 0 : max(1, text.count / 4))
    }

    public func renderContent() async -> String? {
        guard !text.isEmpty else { return nil }
        return text
    }
}

public struct ContextPrompt: PrimitiveContextSection {
    public let id: String
    public let text: String
    public let priority: Int
    public let compression: CompressionStrategy
    public let cachePolicy: CachePolicy
    private let estimatedTokenOverride: Int?

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
        self.estimatedTokenOverride = estimatedTokens
    }

    public var role: PromptSectionRole {
        .context
    }

    public var estimatedTokens: Int {
        estimatedTokenOverride ?? (text.isEmpty ? 0 : max(1, text.count / 4))
    }

    public func renderContent() async -> String? {
        guard !text.isEmpty else { return nil }
        return text
    }
}

public struct UserPrompt: PrimitiveContextSection {
    public let id: String
    public let text: String
    public let priority: Int
    private let estimatedTokenOverride: Int?

    public init(
        _ text: String,
        id: String = "user_query",
        priority: Int = 10,
        estimatedTokens: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.priority = priority
        self.estimatedTokenOverride = estimatedTokens
    }

    public var role: PromptSectionRole {
        .userQuery
    }

    public var compression: CompressionStrategy {
        .keep
    }

    public var cachePolicy: CachePolicy {
        .volatile
    }

    public var estimatedTokens: Int {
        estimatedTokenOverride ?? (text.isEmpty ? 0 : max(1, text.count / 4))
    }

    public func renderContent() async -> String? {
        guard !text.isEmpty else { return nil }
        return text
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
            partialResult += max(1, message.content.count / 4)
        })
    }

    public var historyMessages: [Message]? {
        messages
    }

    public func renderContent() async -> String? {
        nil
    }
}

public struct EmptyPromptSection: ContextSection {
    public init() {}

    public var body: some ContextSection {
        NeverSection()
    }

    public var sectionPathComponent: String? {
        nil
    }

    public func resolve(in context: ContextSectionResolutionContext) -> [ResolvedContextSection] {
        []
    }
}
