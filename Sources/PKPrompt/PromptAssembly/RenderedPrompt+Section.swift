import Foundation

extension RenderedPrompt {
    /// A rendered snapshot of a single prompt section.
    public struct Section: Sendable, Equatable, Codable {
        /// Stable section identifier.
        public let id: String
        
        /// Semantic role used by downstream projections.
        public let role: PromptSectionRole
        
        /// Effective prompt ordering priority.
        public let priority: Int
        
        /// Estimated token count for this rendered section.
        public let estimatedTokens: Int
        
        /// Requested compression strategy for this section.
        public let compression: CompressionStrategy
        
        /// Concrete rendered section type.
        public let type: PromptSectionType
        
        /// Cache policy inherited by this section.
        public let cachePolicy: CachePolicy
        
        /// Canonical node path for this section.
        public let path: [String]
        
        /// Stable parent section identifier when present.
        public let parentID: String?
        
        /// Compression details captured during assembly.
        public let compressionOutcome: CompressionNodeReport?
        
        /// Rendered content payload.
        public let content: PromptSection.Content
        
        /// Creates a rendered prompt section snapshot.
        public init(
            id: String,
            role: PromptSectionRole,
            priority: Int,
            estimatedTokens: Int,
            compression: CompressionStrategy,
            type: PromptSectionType,
            cachePolicy: CachePolicy,
            path: [String],
            parentID: String?,
            compressionOutcome: CompressionNodeReport? = nil,
            content: PromptSection.Content
        ) {
            self.id = id
            self.role = role
            self.priority = priority
            self.estimatedTokens = estimatedTokens
            self.compression = compression
            self.type = type
            self.cachePolicy = cachePolicy
            self.path = path
            self.parentID = parentID
            self.compressionOutcome = compressionOutcome
            self.content = content
        }
    }
}
