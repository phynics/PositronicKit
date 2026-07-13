import Foundation
import PKShared
import PKUtilities

extension RenderedPrompt.Section {
    /// Derives structured node metadata for this rendered section using its content.
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
