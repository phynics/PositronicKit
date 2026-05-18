import Foundation
import PKPrompt
import PKShared

/// Runtime-local helpers for deriving structured prompt metadata used by compression and
/// prompt-history bookkeeping.
///
/// This keeps `PromptAssembler` and `TimelinePromptHistory` aligned on the exact hash inputs that
/// invalidate a node. The helper intentionally lives in the runtime layer because the metadata is
/// only used by runtime-side compression and diff/cache coordination.
enum StructuredPromptMetadata {
    static func makeNodeMetadata(
        id: String,
        estimatedTokens: Int,
        priority: Int,
        cachePolicy: CachePolicy,
        path: [String],
        renderedContent: String
    ) -> StructuredNodeMetadata {
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

    static func makeNodeMetadata(for section: PromptSection, renderedContent: String) -> StructuredNodeMetadata {
        makeNodeMetadata(
            id: section.id,
            estimatedTokens: section.estimatedTokens,
            priority: section.priority,
            cachePolicy: section.cachePolicy,
            path: section.path,
            renderedContent: renderedContent
        )
    }

    static func makeNodeMetadata(for section: RenderedPrompt.Section, renderedContent: String) -> StructuredNodeMetadata {
        makeNodeMetadata(
            id: section.id,
            estimatedTokens: section.estimatedTokens,
            priority: section.priority,
            cachePolicy: section.cachePolicy,
            path: section.path,
            renderedContent: renderedContent
        )
    }
}
