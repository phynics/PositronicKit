import Foundation
import PKShared

public struct TextSection: PromptLeaf {
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
