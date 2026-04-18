import Foundation

public struct ContextPrompt: PromptComposite {
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

    public var body: some PromptComposite {
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
