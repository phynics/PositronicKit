import PKContracts

package struct MultimodalPromptPrimitive: PromptPrimitive {
    package let id: String
    package let messageContent: MessageContent
    package let role: PromptSectionRole
    package let priority: Int
    package let compression: CompressionStrategy
    package let cachePolicy: CachePolicy
    package let tokenEstimate: Int?

    package init(
        id: String,
        content: MessageContent,
        role: PromptSectionRole = .userQuery,
        priority: Int = 10,
        estimatedTokens: Int? = nil,
        compression: CompressionStrategy = .keep,
        cachePolicy: CachePolicy = .volatile
    ) {
        self.id = id
        messageContent = content
        self.role = role
        self.priority = priority
        tokenEstimate = estimatedTokens
        self.compression = compression
        self.cachePolicy = cachePolicy
    }

    package var estimatedTokens: Int { tokenEstimate ?? messageContent.estimatedTokens }
    package var content: PromptPrimitiveContent {
        if messageContent.requiresContentPartsEncoding {
            return .multimodal(messageContent)
        }
        return .text { messageContent.text }
    }
    package func renderContent() async -> String? { messageContent.text }
}
