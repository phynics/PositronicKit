import Foundation

public struct SystemPrompt: Prompt {
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

    public var body: some Prompt {
        PromptPrimitives.Text(
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
