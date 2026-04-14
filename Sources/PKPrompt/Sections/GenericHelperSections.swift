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
