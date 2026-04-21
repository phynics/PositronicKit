import Foundation

public struct ContextPrompt: Prompt {
    public let id: String
    public let priority: Int
    public let compression: CompressionStrategy
    public let cachePolicy: CachePolicy
    public let estimatedTokens: Int?
    private let renderText: @Sendable () async -> String?

    public init(
        _ text: String,
        id: String,
        priority: Int = PromptPriority.medium.rawValue,
        compression: CompressionStrategy = .keep,
        cachePolicy: CachePolicy = .volatile,
        estimatedTokens: Int? = nil
    ) {
        self.init(
            id: id,
            priority: priority,
            compression: compression,
            cachePolicy: cachePolicy,
            estimatedTokens: estimatedTokens,
            render: { text }
        )
    }

    public init(
        id: String,
        priority: Int = PromptPriority.medium.rawValue,
        compression: CompressionStrategy = .keep,
        cachePolicy: CachePolicy = .volatile,
        estimatedTokens: Int? = nil,
        render: @escaping @Sendable () async -> String?
    ) {
        self.id = id
        self.priority = priority
        self.compression = compression
        self.cachePolicy = cachePolicy
        self.estimatedTokens = estimatedTokens
        self.renderText = render
    }

    public var body: some Prompt {
        PromptPrimitives.Text(
            id: id,
            role: .context,
            priority: priority,
            compression: compression,
            cachePolicy: cachePolicy,
            estimatedTokens: estimatedTokens,
            render: renderText
        )
    }
}
