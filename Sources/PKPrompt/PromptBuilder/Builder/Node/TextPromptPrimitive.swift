import Foundation
import PKShared

package struct TextPromptPrimitive: PromptPrimitive {
    package let id: String
    package let role: PromptSectionRole
    package let priority: Int
    package let compression: CompressionStrategy
    package let cachePolicy: CachePolicy
    package let inheritsCachePolicy: Bool
    private let estimatedTokenOverride: Int?
    private let renderText: @Sendable () async -> String?

    package init(
        id: String,
        text: String,
        role: PromptSectionRole = .context,
        priority: Int = 50,
        compression: CompressionStrategy = .keep,
        cachePolicy: CachePolicy = .volatile,
        inheritsCachePolicy: Bool = true,
        estimatedTokens: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.priority = priority
        self.compression = compression
        self.cachePolicy = cachePolicy
        self.inheritsCachePolicy = inheritsCachePolicy
        self.estimatedTokenOverride = estimatedTokens
        self.renderText = { text }
    }

    package init(
        id: String,
        role: PromptSectionRole = .context,
        priority: Int = 50,
        compression: CompressionStrategy = .keep,
        cachePolicy: CachePolicy = .volatile,
        inheritsCachePolicy: Bool = true,
        estimatedTokens: Int? = nil,
        render: @escaping @Sendable () async -> String?
    ) {
        self.id = id
        self.role = role
        self.priority = priority
        self.compression = compression
        self.cachePolicy = cachePolicy
        self.inheritsCachePolicy = inheritsCachePolicy
        self.estimatedTokenOverride = estimatedTokens
        self.renderText = render
    }

    package func renderContent() async -> String? {
        guard let text = await renderText(), !text.isEmpty else { return nil }
        return text
    }

    package var estimatedTokens: Int {
        estimatedTokenOverride ?? 0
    }
}
