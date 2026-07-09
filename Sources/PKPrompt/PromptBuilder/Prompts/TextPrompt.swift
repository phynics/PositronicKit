import Foundation

/// A general-purpose free-text section in the ``PromptBuilder`` DSL, used for arbitrary
/// context/background content (`role: .context`) that isn't the system instructions,
/// user query, or chat history. Content can be a static string or lazily produced via the
/// `render` closure overload (useful for content that's expensive or async to compute).
public struct TextPrompt: Prompt {
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
        renderText = render
    }

    public var body: some Prompt {
        TextPromptPrimitive(
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
