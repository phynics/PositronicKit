import Foundation
import PKShared

extension PromptPrimitives {
    package struct Text: PromptPrimitive {
        package let id: String
        package let text: String
        package let role: PromptSectionRole
        package let priority: Int
        package let compression: CompressionStrategy
        package let cachePolicy: CachePolicy
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
            self.id = id
            self.text = text
            self.role = role
            self.priority = priority
            self.compression = compression
            self.cachePolicy = cachePolicy
            self.estimatedTokenOverride = estimatedTokens
        }

        package func renderContent() async -> String? {
            guard !text.isEmpty else { return nil }
            return text
        }

        package var estimatedTokens: Int {
            estimatedTokenOverride ?? 0
        }
    }
}
