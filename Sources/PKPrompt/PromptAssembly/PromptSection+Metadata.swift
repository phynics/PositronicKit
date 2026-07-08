import Foundation
import PKShared

extension PromptSection {
    /// Derives structured node metadata for this section using its resolved content.
    public func nodeMetadata(renderedContent: String) -> StructuredNodeMetadata {
        StructuredNodeMetadata(
            path: path,
            nodeHash: StableHash.hash(components: [
                id,
                String(estimatedTokens),
                String(priority),
                String(describing: cachePolicy),
                renderedContent,
            ])
        )
    }
}
