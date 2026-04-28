import Foundation
import PKShared

extension PromptPrimitives {
    package struct Text: PromptPrimitive {
        package let id: String
        package let role: PromptSectionRole
        package let priority: Int
        package let compression: CompressionStrategy
        package let cachePolicy: CachePolicy
        private let renderTextClosure: @Sendable () async -> String?
        private let estimatedTokenOverride: Int?

        package init(
            id: String,
            text: String,
            role: PromptSectionRole = .context,
            priority: Int = 50,
            compression: CompressionStrategy = .keep,
            cachePolicy: CachePolicy = .volatile,
            estimatedTokens: Int? = nil
        ) {
            self.init(
                id: id,
                role: role,
                priority: priority,
                compression: compression,
                cachePolicy: cachePolicy,
                estimatedTokens: estimatedTokens,
                render: { text }
            )
        }

        package init(
            id: String,
            role: PromptSectionRole = .context,
            priority: Int = 50,
            compression: CompressionStrategy = .keep,
            cachePolicy: CachePolicy = .volatile,
            estimatedTokens: Int? = nil,
            render: @escaping @Sendable () async -> String?
        ) {
            self.id = id
            self.role = role
            self.priority = priority
            self.compression = compression
            self.cachePolicy = cachePolicy
            self.renderTextClosure = render
            self.estimatedTokenOverride = estimatedTokens
        }

        package func renderContent() async -> String? {
            guard let text = await renderTextClosure(), !text.isEmpty else { return nil }
            return text
        }

        package var estimatedTokens: Int {
            estimatedTokenOverride ?? 0
        }
    }
}
